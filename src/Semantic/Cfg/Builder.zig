//! Mutable state machine that lowers Zig's AST into a `Cfg`.
//!
//! `SemanticBuilder` drives this as it walks the tree. Every method is a no-op
//! when no container is open, so hooks may be called unconditionally.
//!
//! ## Known limitations
//! - A `defer`/`errdefer` body is lowered as a single `.cleanup` instruction on
//!   each exit path that runs it. Control flow *within* the body is not
//!   re-lowered, because the builder visits each AST node exactly once.
//! - When a `noreturn` callee is bound after its call site, the call's block is
//!   split during `resolvePendingCalls`. Nodes lowered after the split still map
//!   to the original block in `NodeLinks.blocks`.
//! - `chain_cache` assumes `(depth, target, edge kind, is_error)` uniquely
//!   determines the cleanup floor. Break/continue join blocks are created fresh
//!   per construct, so this holds.

const CfgBuilder = @This();

/// Borrowed. Owned by `Semantic`.
draft: *Draft,
/// Block currently being appended to. `.none` when outside a container, or in
/// dead code after a terminator.
curr: BasicBlock.Id.Optional = .none,
/// Container currently being built.
container: Container.Id.Optional = .none,
/// Ambient flags merged into every new block. Carries `b_comptime` through
/// `comptime` regions, `inline` loops, and `inline` prongs.
curr_flags: BasicBlock.Flags = .empty,
/// `cleanups.items.len` when the current container was entered. The cleanup
/// floor for `return` and for `try`'s error edge.
cleanup_base: u32 = 0,
/// Enclosing loops / labeled switches / labeled blocks, for break/continue
/// resolution.
labels: std.ArrayList(Label) = .empty,
/// `labels.items.len` when the current container was entered. Frames below it
/// belong to an enclosing container and are not visible to jumps in this one.
label_base: u32 = 0,
/// Pending `defer`/`errdefer` bodies, innermost last. Frames delimited by `scopes`.
cleanups: std.ArrayList(Cleanup) = .empty,
/// `cleanups.items.len` at each scope entry.
scopes: std.ArrayList(u32) = .empty,
/// Memoized cleanup chains, keyed by `(depth, target, kind, err)`. Prevents
/// chain blowup on N exits x M defers.
chain_cache: std.ArrayList(ChainEntry) = .empty,
/// Calls whose callee was not bound yet when they were lowered. Re-resolved
/// after the walk, since container decls are order independent.
pending_calls: std.ArrayList(PendingCall) = .empty,

pub fn deinit(self: *CfgBuilder, alloc: Allocator) void {
    self.labels.deinit(alloc);
    self.cleanups.deinit(alloc);
    self.scopes.deinit(alloc);
    self.chain_cache.deinit(alloc);
    self.pending_calls.deinit(alloc);
}

// ── containers ───────────────────────────────────────────────────────────────

/// Open a new control-flow container and move into its body block.
///
/// Containers nest (a `fn_decl` inside a top-level decl initializer, say), so
/// the returned frame must be passed back to `exitContainer`.
pub fn enterContainer(self: *CfgBuilder, alloc: Allocator, opts: NewContainer) Allocator.Error!ContainerFrame {
    const frame: ContainerFrame = .{
        .container = self.container,
        .curr = self.curr,
        .flags = self.curr_flags,
        .cleanup_base = self.cleanup_base,
        .label_base = self.label_base,
        .labels = @intCast(self.labels.items.len),
        .cleanups = @intCast(self.cleanups.items.len),
        .scopes = @intCast(self.scopes.items.len),
        .chains = @intCast(self.chain_cache.items.len),
    };

    const id: Container.Id = .from(self.draft.containers.len);
    self.container = id.into(Container.Id.Optional);
    self.curr_flags.b_comptime = opts.is_comptime;
    self.cleanup_base = @intCast(self.cleanups.items.len);
    self.label_base = frame.labels;

    const entry = try self.newBlock(alloc, opts.node, .{ .b_entry = true });
    const exit = try self.newBlock(alloc, opts.node, .{ .b_exit = true });
    const body = try self.newBlock(alloc, opts.node, .{});
    try self.draft.addEdge(alloc, entry, .{ .dest = body, .kind = .normal });
    _ = try self.draft.addContainer(alloc, .{
        .node = opts.node,
        .symbol = opts.symbol,
        .entry = entry,
        .exit = exit,
        .flags = opts.flags,
    });

    self.curr = body.into(BasicBlock.Id.Optional);
    return frame;
}

/// Fall through to the container's exit block and restore the enclosing
/// container's state.
pub inline fn exitContainer(self: *CfgBuilder, alloc: Allocator, frame: ContainerFrame) void {
    self.finishContainer(alloc, frame) catch @panic("OOM");
}

fn finishContainer(self: *CfgBuilder, alloc: Allocator, frame: ContainerFrame) Allocator.Error!void {
    if (self.container.unwrap()) |id| {
        if (self.curr.unwrap()) |curr| {
            const exit = self.draft.getContainer(id).exit;
            try self.draft.addEdge(alloc, curr, .{ .dest = exit, .kind = .normal });
        }
    }

    self.labels.shrinkRetainingCapacity(frame.labels);
    self.cleanups.shrinkRetainingCapacity(frame.cleanups);
    self.scopes.shrinkRetainingCapacity(frame.scopes);
    self.chain_cache.shrinkRetainingCapacity(frame.chains);

    self.container = frame.container;
    self.curr = frame.curr;
    self.curr_flags = frame.flags;
    self.cleanup_base = frame.cleanup_base;
    self.label_base = frame.label_base;
}

// ============================ SCOPES AND CLEANUPS ============================

/// Push a cleanup frame. Pending `defer`s declared above it run when it is popped.
pub fn enterScope(self: *CfgBuilder, alloc: Allocator) Allocator.Error!void {
    if (self.container == .none) return;
    try self.scopes.append(alloc, @intCast(self.cleanups.items.len));
}

/// Pop a cleanup frame, running its `defer`s on the fallthrough path.
pub inline fn exitScope(self: *CfgBuilder, alloc: Allocator) void {
    self.finishScope(alloc) catch @panic("OOM");
}

fn finishScope(self: *CfgBuilder, alloc: Allocator) Allocator.Error!void {
    if (self.container == .none) return;
    const floor = self.scopes.pop() orelse return;
    defer {
        self.cleanups.shrinkRetainingCapacity(floor);
        self.dropChains(floor);
    }
    if (self.curr == .none) return;
    if (!self.hasCleanups(floor, false)) return;

    const from = self.curr.unwrap().?;
    const head = try self.newCleanupBlock(alloc, floor, false);
    try self.draft.addEdge(alloc, from, .{ .dest = head, .kind = .cleanup });
    self.curr = head.into(BasicBlock.Id.Optional);
}

/// Register a `defer`/`errdefer` body. It is lowered at each exit path that
/// runs it, never at the declaration site.
pub fn pushCleanup(self: *CfgBuilder, alloc: Allocator, body: NodeIndex, is_errdefer: bool) Allocator.Error!void {
    if (self.container == .none) return;
    try self.cleanups.append(alloc, .{ .body = body, .is_errdefer = is_errdefer });
}

/// Stop lowering into the current block. A `defer`/`errdefer` body does not
/// execute at its declaration site, so every block it forces into existence is
/// orphaned.
pub inline fn enterOrphan(self: *CfgBuilder) BasicBlock.Id.Optional {
    defer self.curr = .none;
    return self.curr;
}

/// Close an orphan region and go back to `prev`. The region's trailing block
/// leads nowhere, so terminate it instead of leaving a successor-less `.goto`
/// block behind.
pub inline fn exitOrphan(self: *CfgBuilder, prev: BasicBlock.Id.Optional) void {
    if (self.curr.unwrap()) |id| {
        if (self.draft.successorsOf(id).len == 0) {
            self.draft.blockMut(id).terminator.* = .{ .kind = .@"unreachable" };
        }
    }
    self.curr = prev;
}

// ── instructions ─────────────────────────────────────────────────────────────

/// Append an instruction to the current block.
pub fn emit(self: *CfgBuilder, alloc: Allocator, node: NodeIndex, kind: Instruction.Kind) Allocator.Error!void {
    if (self.container == .none) return;
    const id = try self.currBlock(alloc, node);

    const block = self.draft.blockMut(id);
    if (block.instructions.len == 0) block.instructions.start = .from(self.draft.instructions.len);
    _ = try self.draft.addInstruction(alloc, .{ .node = node, .kind = kind });
    block.instructions.len += 1;
}

// ── branches ─────────────────────────────────────────────────────────────────

/// Split the current block into a two-way branch and move into the first arm.
///
/// Call `nextArm` to move to the second arm (only when `has_alt`), then
/// `endBranch` to reconverge.
pub fn beginBranch(self: *CfgBuilder, alloc: Allocator, opts: Branch.New) Allocator.Error!Branch {
    if (self.container == .none) return .{};
    const from = try self.currBlock(alloc, opts.node);

    const then_blk = try self.newBlock(alloc, opts.node, opts.then_flags);
    const alt: BasicBlock.Id.Optional = if (opts.has_alt)
        (try self.newBlock(alloc, opts.node, opts.alt_flags)).into(BasicBlock.Id.Optional)
    else
        .none;
    const join = try self.newBlock(alloc, opts.node, .{});

    self.draft.blockMut(from).terminator.* = .{ .kind = .branch, .node = opts.node };
    try self.draft.addEdge(alloc, from, .{ .dest = then_blk, .kind = opts.then_kind });
    try self.draft.addEdge(alloc, from, .{ .dest = alt.unwrap() orelse join, .kind = opts.alt_kind });

    self.curr = then_blk.into(BasicBlock.Id.Optional);
    return .{ .join = join.into(BasicBlock.Id.Optional), .alt = alt };
}

/// End the first arm and move into the second. When there is no second arm the
/// builder enters dead-code mode until `endBranch`.
pub inline fn nextArm(self: *CfgBuilder, alloc: Allocator, branch: Branch) void {
    self.armToJoin(alloc, branch) catch @panic("OOM");
    self.curr = branch.alt;
}

/// End the current arm and continue in the join block.
pub inline fn endBranch(self: *CfgBuilder, alloc: Allocator, branch: Branch) void {
    self.armToJoin(alloc, branch) catch @panic("OOM");
    self.curr = branch.join;
}

fn armToJoin(self: *CfgBuilder, alloc: Allocator, branch: Branch) Allocator.Error!void {
    const join = branch.join.unwrap() orelse return;
    const from = self.curr.unwrap() orelse return;
    try self.draft.addEdge(alloc, from, .{ .dest = join, .kind = .normal });
}

// ── loops ────────────────────────────────────────────────────────────────────

/// Create a loop header and move into it. The caller lowers the condition
/// next, then calls `loopBody`.
pub fn beginLoop(self: *CfgBuilder, alloc: Allocator, node: NodeIndex, is_inline: bool) Allocator.Error!Loop {
    if (self.container == .none) return .{};
    const pre = try self.currBlock(alloc, node);

    var loop: Loop = .{ .flags = self.curr_flags };
    if (is_inline) self.curr_flags.b_comptime = true;

    const header = try self.newBlock(alloc, node, .{ .b_loop_header = true });
    try self.draft.addEdge(alloc, pre, .{ .dest = header, .kind = .normal });
    self.curr = header.into(BasicBlock.Id.Optional);
    loop.header = header.into(BasicBlock.Id.Optional);

    return loop;
}

/// Terminate the condition block, create the body/cont/else/exit blocks, and
/// push the loop's label frame.
pub fn loopBody(self: *CfgBuilder, alloc: Allocator, loop: *Loop, opts: Loop.Body) Allocator.Error!void {
    if (loop.header == .none) return;
    const from = try self.currBlock(alloc, opts.node);

    const body = try self.newBlock(alloc, opts.node, .{});
    const cont = try self.newBlock(alloc, opts.node, .{});
    const else_blk: BasicBlock.Id.Optional = if (opts.has_else)
        (try self.newBlock(alloc, opts.node, .{ .b_error = opts.else_kind == .@"error" })).into(BasicBlock.Id.Optional)
    else
        .none;
    const exit = try self.newBlock(alloc, opts.node, .{});

    self.draft.blockMut(from).terminator.* = .{ .kind = .branch, .node = opts.node };
    try self.draft.addEdge(alloc, from, .{ .dest = body, .kind = .true_branch });
    try self.draft.addEdge(alloc, from, .{ .dest = else_blk.unwrap() orelse exit, .kind = opts.else_kind });

    loop.body = body.into(BasicBlock.Id.Optional);
    loop.cont = cont.into(BasicBlock.Id.Optional);
    loop.@"else" = else_blk;
    loop.exit = exit.into(BasicBlock.Id.Optional);
    loop.labeled = true;
    loop.frame = @intCast(self.labels.items.len);

    try self.labels.append(alloc, .{
        .kind = .loop,
        .label = opts.label,
        .break_target = exit,
        .continue_target = cont.into(BasicBlock.Id.Optional),
        .cleanup_depth = @intCast(self.cleanups.items.len),
    });
    self.curr = .none;
}

/// Move into the loop's continue block, where `: (i += 1)` is lowered.
pub inline fn enterCont(self: *CfgBuilder, loop: *const Loop) void {
    if (loop.cont == .none) return;
    self.curr = loop.cont;
}

/// Wire the continue block's back edge to the header.
pub inline fn exitCont(self: *CfgBuilder, alloc: Allocator, loop: *const Loop) void {
    self.backEdge(alloc, loop) catch @panic("OOM");
}

fn backEdge(self: *CfgBuilder, alloc: Allocator, loop: *const Loop) Allocator.Error!void {
    const header = loop.header.unwrap() orelse return;
    const from = self.curr.unwrap() orelse return;
    try self.draft.addEdge(alloc, from, .{ .dest = header, .kind = .back });
    self.curr = .none;
}

/// Move into the loop body.
pub inline fn enterLoopBody(self: *CfgBuilder, loop: *const Loop) void {
    if (loop.body == .none) return;
    self.curr = loop.body;
}

/// Fall through from the loop body into the continue block.
pub inline fn exitLoopBody(self: *CfgBuilder, alloc: Allocator, loop: *const Loop) void {
    self.bodyToCont(alloc, loop) catch @panic("OOM");
}

fn bodyToCont(self: *CfgBuilder, alloc: Allocator, loop: *const Loop) Allocator.Error!void {
    const cont = loop.cont.unwrap() orelse return;
    if (self.curr.unwrap()) |from| {
        try self.draft.addEdge(alloc, from, .{ .dest = cont, .kind = .normal });
    }
    self.curr = .none;
}

/// Move into the loop's `else` block, if it has one. `break` bypasses it.
///
/// The loop is over by the time its `else` runs, so its frame stops capturing
/// unlabeled jumps: they bind to the enclosing loop instead.
pub inline fn enterLoopElse(self: *CfgBuilder, loop: *const Loop) void {
    if (loop.header == .none) return;
    if (loop.labeled) self.labels.items[loop.frame].active = false;
    self.curr = loop.@"else";
}

/// Pop the loop's label frame and continue after the loop.
pub inline fn endLoop(self: *CfgBuilder, alloc: Allocator, loop: *const Loop) void {
    self.finishLoop(alloc, loop) catch @panic("OOM");
}

fn finishLoop(self: *CfgBuilder, alloc: Allocator, loop: *const Loop) Allocator.Error!void {
    const exit = loop.exit.unwrap() orelse return;
    if (loop.labeled) {
        assert(
            loop.frame + 1 == self.labels.items.len,
            "Loop label frame is not on top of the stack ({d} != {d})",
            .{ loop.frame + 1, self.labels.items.len },
        );
        _ = self.labels.pop();
    }
    if (self.curr.unwrap()) |from| {
        try self.draft.addEdge(alloc, from, .{ .dest = exit, .kind = .normal });
    }
    self.curr_flags = loop.flags;
    self.curr = exit.into(BasicBlock.Id.Optional);
}

// ── switch ───────────────────────────────────────────────────────────────────

/// Lower the switch operand, then terminate its block as a switch dispatch.
///
/// A labeled switch's dispatch is a loop header: `continue :lbl v` re-enters
/// it. It therefore gets a fresh block, the way `beginLoop` does, so that only
/// the operand — and not whatever preceded the switch — sits inside the loop.
/// An unlabeled dispatch is not a jump target, so it reuses the current block.
pub fn beginSwitch(
    self: *CfgBuilder,
    alloc: Allocator,
    node: NodeIndex,
    operand: NodeIndex,
    label: MaybeTokenId,
) Allocator.Error!Switch {
    if (self.container == .none) return .{};

    if (label != .none) {
        const pre = try self.currBlock(alloc, node);
        const header = try self.newBlock(alloc, node, .{ .b_loop_header = true });
        try self.draft.addEdge(alloc, pre, .{ .dest = header, .kind = .normal });
        self.curr = header.into(BasicBlock.Id.Optional);
    }
    try self.emit(alloc, operand, .condition);

    const dispatch = try self.currBlock(alloc, node);
    const join = try self.newBlock(alloc, node, .{});
    self.draft.blockMut(dispatch).terminator.* = .{ .kind = .@"switch", .node = node };

    if (label != .none) {
        try self.labels.append(alloc, .{
            .kind = .@"switch",
            .label = label,
            .break_target = join,
            .continue_target = dispatch.into(BasicBlock.Id.Optional),
            .cleanup_depth = @intCast(self.cleanups.items.len),
        });
    }

    self.curr = .none;
    return .{
        .dispatch = dispatch.into(BasicBlock.Id.Optional),
        .join = join.into(BasicBlock.Id.Optional),
        .flags = self.curr_flags,
        .labeled = label != .none,
    };
}

/// Start a prong. Zig has no fallthrough, so each prong is an independent
/// successor of the dispatch block.
///
/// An `inline` prong is a comptime region for its whole duration, so the flag
/// is ambient until `endSwitchProng` restores it.
pub fn switchProng(self: *CfgBuilder, alloc: Allocator, sw: *const Switch, node: NodeIndex, is_inline: bool) Allocator.Error!void {
    const dispatch = sw.dispatch.unwrap() orelse return;
    if (is_inline) self.curr_flags.b_comptime = true;

    const prong = try self.newBlock(alloc, node, .{});
    try self.draft.addEdge(alloc, dispatch, .{ .dest = prong, .kind = .true_branch });
    self.curr = prong.into(BasicBlock.Id.Optional);
}

/// End a prong, joining it with the rest of the switch.
pub inline fn endSwitchProng(self: *CfgBuilder, alloc: Allocator, sw: *const Switch) void {
    self.prongToJoin(alloc, sw) catch @panic("OOM");
}

fn prongToJoin(self: *CfgBuilder, alloc: Allocator, sw: *const Switch) Allocator.Error!void {
    const join = sw.join.unwrap() orelse return;
    self.curr_flags = sw.flags;
    if (self.curr.unwrap()) |from| {
        try self.draft.addEdge(alloc, from, .{ .dest = join, .kind = .normal });
    }
    self.curr = .none;
}

/// Continue after the switch. Without an `else` prong a conservative
/// `dispatch -false-> join` edge is added: zlint cannot prove exhaustiveness.
pub inline fn endSwitch(self: *CfgBuilder, alloc: Allocator, sw: *const Switch, has_else: bool) void {
    self.finishSwitch(alloc, sw, has_else) catch @panic("OOM");
}

fn finishSwitch(self: *CfgBuilder, alloc: Allocator, sw: *const Switch, has_else: bool) Allocator.Error!void {
    const join = sw.join.unwrap() orelse return;
    if (!has_else) {
        try self.draft.addEdge(alloc, sw.dispatch.unwrap().?, .{ .dest = join, .kind = .false_branch });
    }
    if (sw.labeled) _ = self.labels.pop();
    self.curr = join.into(BasicBlock.Id.Optional);
}

// ── labeled blocks ───────────────────────────────────────────────────────────

/// Push a label frame for `blk: { ... }`. Returns the join block that
/// `break :blk` targets.
pub fn beginLabeledBlock(self: *CfgBuilder, alloc: Allocator, node: NodeIndex, label: MaybeTokenId) Allocator.Error!BasicBlock.Id.Optional {
    if (self.container == .none or label == .none) return .none;
    _ = try self.currBlock(alloc, node);

    const join = try self.newBlock(alloc, node, .{});
    try self.labels.append(alloc, .{
        .kind = .block,
        .label = label,
        .break_target = join,
        .cleanup_depth = @intCast(self.cleanups.items.len),
    });

    return join.into(BasicBlock.Id.Optional);
}

/// Pop the label frame and continue in the join block.
pub inline fn endLabeledBlock(self: *CfgBuilder, alloc: Allocator, join: BasicBlock.Id.Optional) void {
    self.finishLabeledBlock(alloc, join) catch @panic("OOM");
}

fn finishLabeledBlock(self: *CfgBuilder, alloc: Allocator, join: BasicBlock.Id.Optional) Allocator.Error!void {
    const dest = join.unwrap() orelse return;
    _ = self.labels.pop();
    if (self.curr.unwrap()) |from| {
        try self.draft.addEdge(alloc, from, .{ .dest = dest, .kind = .normal });
    }
    self.curr = dest.into(BasicBlock.Id.Optional);
}

// ── terminators ──────────────────────────────────────────────────────────────

/// End the current block without adding any successors.
pub fn terminate(self: *CfgBuilder, kind: Terminator.Kind, node: NodeIndex) void {
    const id = self.curr.unwrap() orelse return;
    self.draft.blockMut(id).terminator.* = .{ .kind = kind, .node = node };
    self.curr = .none;
}

/// Run the container's cleanup chain, then jump to its exit block.
///
/// `is_error` should only be set when the operand is syntactically
/// `error.Foo`; zlint has no types.
pub fn onReturn(self: *CfgBuilder, alloc: Allocator, node: NodeIndex, is_error: bool) Allocator.Error!void {
    if (self.container.unwrap()) |id| {
        const exit = self.draft.getContainer(id).exit;
        try self.exitEdge(alloc, exit, .normal, self.cleanup_base, is_error);
    }
    self.terminate(.@"return", node);
}

/// Split at a `try`. The error edge runs errdefers *and* defers on the way to
/// the container exit; the ok edge falls through.
pub fn onTry(self: *CfgBuilder, alloc: Allocator, node: NodeIndex) Allocator.Error!void {
    const id = self.container.unwrap() orelse return;
    if (self.curr == .none) return;

    const ok = try self.newBlock(alloc, node, .{});
    const from = self.curr.unwrap().?;
    self.draft.blockMut(from).terminator.* = .{ .kind = .branch, .node = node };

    const exit = self.draft.getContainer(id).exit;
    try self.exitEdge(alloc, exit, .@"error", self.cleanup_base, true);
    try self.draft.addEdge(alloc, from, .{ .dest = ok, .kind = .normal });
    self.curr = ok.into(BasicBlock.Id.Optional);
}

/// Jump out of the construct at `labels.items[index]`.
pub fn onBreak(self: *CfgBuilder, alloc: Allocator, index: usize, node: NodeIndex) Allocator.Error!void {
    const label = self.labels.items[index];
    try self.exitEdge(alloc, label.break_target, .jump, label.cleanup_depth, false);
    self.terminate(.@"break", node);
}

/// Jump to a loop's continue block, or back into a labeled switch's dispatch
/// block. `Label.kind` disambiguates the two meanings of `continue`.
pub fn onContinue(self: *CfgBuilder, alloc: Allocator, index: usize, node: NodeIndex) Allocator.Error!void {
    const label = self.labels.items[index];
    // `continue :blk` where `blk` is a labeled block is `error: continue
    // outside of loop or labeled switch expression`. Model it as a dead end so
    // the block does not end up successor-less.
    const target = label.continue_target.unwrap() orelse {
        return self.terminate(.@"unreachable", node);
    };

    const kind: Edge.Kind = if (label.kind == .@"switch") .back else .jump;
    try self.exitEdge(alloc, target, kind, label.cleanup_depth, false);
    self.terminate(.@"continue", node);
}

// ── label resolution ─────────────────────────────────────────────────────────

/// Innermost enclosing loop, for unlabeled `break`/`continue`. Zig's `switch`
/// does not capture unlabeled jumps.
pub fn innermostLoop(self: *const CfgBuilder) ?usize {
    var i = self.labels.items.len;
    while (i > self.label_base) {
        i -= 1;
        const label = self.labels.items[i];
        if (label.kind == .loop and label.active) return i;
    }
    return null;
}

// ── internals ────────────────────────────────────────────────────────────────

/// The block instructions should be appended to.
///
/// Materializes a block when the builder is in dead code (so it can be reported
/// as unreachable), splits the current block when a nested container was
/// lowered into the instruction arena after it, and splits it again when the
/// ambient flags no longer describe it (entering or leaving a `comptime`
/// region).
fn currBlock(self: *CfgBuilder, alloc: Allocator, node: NodeIndex) Allocator.Error!BasicBlock.Id {
    const id = self.curr.unwrap() orelse {
        const dead = try self.newBlock(alloc, node, .{});
        self.curr = dead.into(BasicBlock.Id.Optional);
        return dead;
    };

    const block = self.draft.blockMut(id);
    const range = block.instructions.*;
    const stale = block.flags.b_comptime != self.curr_flags.b_comptime;
    if (!stale and (range.len == 0 or range.start.int() + range.len == self.draft.instructions.len)) return id;

    const next = try self.newBlock(alloc, node, .{});
    try self.draft.addEdge(alloc, id, .{ .dest = next, .kind = .normal });
    self.curr = next.into(BasicBlock.Id.Optional);
    return next;
}

fn newBlock(self: *CfgBuilder, alloc: Allocator, node: NodeIndex, flags: BasicBlock.Flags) Allocator.Error!BasicBlock.Id {
    const container = self.container.unwrap() orelse {
        @branchHint(.cold);
        std.debug.panic("CfgBuilder.newBlock called outside of a container", .{});
    };
    return self.draft.addBlock(alloc, .{
        .container = container,
        .node = node,
        .flags = flags.merge(self.curr_flags),
    });
}

/// Add an outgoing edge from the current block, routing it through a cleanup
/// chain when any `defer`/`errdefer` above `floor` applies.
fn exitEdge(
    self: *CfgBuilder,
    alloc: Allocator,
    target: BasicBlock.Id,
    kind: Edge.Kind,
    floor: u32,
    is_error: bool,
) Allocator.Error!void {
    const from = self.curr.unwrap() orelse return;
    if (!self.hasCleanups(floor, is_error)) {
        return self.draft.addEdge(alloc, from, .{ .dest = target, .kind = kind });
    }

    const head = try self.cleanupChain(alloc, floor, target, kind, is_error);
    return self.draft.addEdge(alloc, from, .{ .dest = head, .kind = .cleanup });
}

fn cleanupChain(
    self: *CfgBuilder,
    alloc: Allocator,
    floor: u32,
    target: BasicBlock.Id,
    kind: Edge.Kind,
    is_error: bool,
) Allocator.Error!BasicBlock.Id {
    const depth: u32 = @intCast(self.cleanups.items.len);
    for (self.chain_cache.items) |entry| {
        if (entry.depth == depth and entry.target == target and entry.kind == kind and entry.err == is_error) {
            return entry.head;
        }
    }

    const head = try self.newCleanupBlock(alloc, floor, is_error);
    try self.draft.addEdge(alloc, head, .{ .dest = target, .kind = kind });
    try self.chain_cache.append(alloc, .{ .depth = depth, .target = target, .kind = kind, .err = is_error, .head = head });

    return head;
}

/// Lower every applicable `defer`/`errdefer` above `floor` into one block, in
/// reverse declaration order. `errdefer`s are filtered out on non-error paths.
fn newCleanupBlock(self: *CfgBuilder, alloc: Allocator, floor: u32, is_error: bool) Allocator.Error!BasicBlock.Id {
    const top = self.cleanups.items.len;
    assert(top > floor, "newCleanupBlock: no pending cleanups ({d} <= {d})", .{ top, floor });

    const block = try self.newBlock(alloc, self.cleanups.items[top - 1].body, .{
        .b_cleanup = true,
        .b_error = is_error,
    });

    const start: u32 = @intCast(self.draft.instructions.len);
    var len: u32 = 0;
    var i = top;
    while (i > floor) {
        i -= 1;
        const cleanup = self.cleanups.items[i];
        if (cleanup.is_errdefer and !is_error) continue;
        _ = try self.draft.addInstruction(alloc, .{ .node = cleanup.body, .kind = .cleanup });
        len += 1;
    }
    self.draft.blockMut(block).instructions.* = .{ .start = .from(start), .len = len };

    return block;
}

fn hasCleanups(self: *const CfgBuilder, floor: u32, is_error: bool) bool {
    var i = self.cleanups.items.len;
    while (i > floor) {
        i -= 1;
        if (is_error or !self.cleanups.items[i].is_errdefer) return true;
    }
    return false;
}

/// Drop memoized chains whose cleanup set is about to go out of scope.
/// Reusing them would run `defer`s from a sibling scope.
fn dropChains(self: *CfgBuilder, floor: u32) void {
    var i: usize = 0;
    while (i < self.chain_cache.items.len) {
        if (self.chain_cache.items[i].depth > floor) {
            _ = self.chain_cache.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

// ── nested types ─────────────────────────────────────────────────────────────

/// An enclosing construct a `break`/`continue` can name.
pub const Label = struct {
    kind: Kind,
    /// Label token if the construct is labeled (`outer: while ...`).
    label: MaybeTokenId = .none,
    /// Whether an *unlabeled* jump can still see this frame. Cleared while a
    /// loop's `else` clause is lowered: the loop has finished by then, so
    /// `break`/`continue` there bind to the enclosing loop. Resolution by name
    /// ignores this — `lbl: while (…) {} else { break :lbl; }` is legal Zig.
    active: bool = true,
    /// Where `break` lands (loop exit / labeled switch join / labeled block join).
    break_target: BasicBlock.Id,
    /// Where `continue` lands: a loop's cont block, or a labeled switch's dispatch.
    continue_target: BasicBlock.Id.Optional = .none,
    /// `cleanups.items.len` when pushed. A jump out of this construct runs
    /// every cleanup above this depth.
    cleanup_depth: u32,

    pub const Kind = enum { loop, @"switch", block };
};

/// A pending `defer`/`errdefer`.
pub const Cleanup = struct {
    /// The deferred expression. Lowered at each exit path that runs it.
    body: NodeIndex,
    is_errdefer: bool,
};

/// A call site whose callee had not been bound when it was lowered.
pub const PendingCall = struct {
    /// The block the call was lowered into.
    block: BasicBlock.Id,
    /// The `call` node.
    node: NodeIndex,
    /// The callee identifier, re-resolved after the walk.
    token: TokenIndex,
    scope: Scope.Id,
    /// `cfg.instructions.len` at the call site: where `block` is cut in two if
    /// the callee turns out to be `noreturn`.
    split: u32,
};

/// A memoized cleanup chain.
pub const ChainEntry = struct {
    depth: u32,
    target: BasicBlock.Id,
    /// Edge kind out of the chain's tail. A `return error.Foo` and a `try`
    /// share `(depth, target, err)` but leave the chain differently.
    kind: Edge.Kind,
    err: bool,
    head: BasicBlock.Id,
};

/// Options for `enterContainer`.
pub const NewContainer = struct {
    /// The `fn_decl` / `test_decl` / `@"comptime"` / decl node.
    node: NodeIndex,
    symbol: Symbol.Id.Optional = .none,
    flags: Container.Flags = .{},
    /// Blocks in this container get `b_comptime`.
    is_comptime: bool = false,
};

/// Saved state of the enclosing container.
pub const ContainerFrame = struct {
    container: Container.Id.Optional,
    curr: BasicBlock.Id.Optional,
    flags: BasicBlock.Flags,
    cleanup_base: u32,
    label_base: u32,
    labels: u32,
    cleanups: u32,
    scopes: u32,
    chains: u32,
};

/// A two-way branch under construction. All fields are `.none` when the CFG is
/// disabled.
pub const Branch = struct {
    join: BasicBlock.Id.Optional = .none,
    alt: BasicBlock.Id.Optional = .none,
    /// Options for `beginBranch`.
    pub const New = struct {
        /// The branching node. Becomes the terminator's node.
        node: NodeIndex,
        /// Edge kind into the first arm.
        then_kind: Edge.Kind = .true_branch,
        /// Edge kind taken when the first arm is not. Targets the join when there
        /// is no second arm.
        alt_kind: Edge.Kind = .false_branch,
        then_flags: BasicBlock.Flags = .{},
        alt_flags: BasicBlock.Flags = .{},
        has_alt: bool = false,
    };
};

/// A loop under construction.
pub const Loop = struct {
    header: BasicBlock.Id.Optional = .none,
    body: BasicBlock.Id.Optional = .none,
    /// Where `continue` lands. `while (c) : (cont)` lowers `cont` here.
    cont: BasicBlock.Id.Optional = .none,
    /// Runs on natural termination only. `break` bypasses it.
    @"else": BasicBlock.Id.Optional = .none,
    exit: BasicBlock.Id.Optional = .none,
    /// Ambient block flags to restore in `endLoop`.
    flags: BasicBlock.Flags = .{},
    /// Whether a label frame was pushed.
    labeled: bool = false,
    /// Index of this loop's frame in `labels`. Only valid when `labeled`.
    frame: u32 = 0,

    /// Options for `loopBody`.
    pub const Body = struct {
        node: NodeIndex,
        label: MaybeTokenId = .none,
        has_else: bool = false,
        /// `.@"error"` for `while (x) |v| ... else |e|`, `.false_branch` otherwise.
        else_kind: Edge.Kind = .false_branch,
    };
};

/// A switch under construction.
pub const Switch = struct {
    dispatch: BasicBlock.Id.Optional = .none,
    join: BasicBlock.Id.Optional = .none,
    /// Ambient block flags to restore at the end of each prong.
    flags: BasicBlock.Flags = .{},
    /// Whether a label frame was pushed.
    labeled: bool = false,
};

const std = @import("std");
const util = @import("util");
const _ast = @import("../ast.zig");

const Allocator = std.mem.Allocator;
const NodeIndex = _ast.NodeIndex;
const TokenIndex = _ast.TokenIndex;
const MaybeTokenId = _ast.MaybeTokenId;

const Draft = @import("Draft.zig");
const Cfg = @import("../Cfg.zig");
const BasicBlock = Cfg.BasicBlock;
const Container = Cfg.Container;
const Edge = Cfg.Edge;
const Instruction = Cfg.Instruction;
const Terminator = Cfg.Terminator;

const Semantic = @import("../../Semantic.zig");
const Scope = Semantic.Scope;
const Symbol = Semantic.Symbol;

const assert = util.assert;

const t = std.testing;

/// Analyze `src` with CFG construction enabled. Caller owns the `Semantic`.
fn buildCfg(src: [:0]const u8) !Semantic {
    var builder: Semantic.Builder = .init(t.allocator);
    defer builder.deinit();
    builder.withCfg(true);

    var result = builder.build(src) catch |e| {
        std.debug.print("Analysis failed on source:\n\n{s}\n\n", .{src});
        return e;
    };
    defer result.deinitErrors();
    errdefer result.value.deinit();
    try t.expect(!result.hasErrors());

    return result.value;
}

/// The unique successor of `from` reached by a `kind` edge.
fn succ(cfg: *const Cfg, from: BasicBlock.Id, kind: Edge.Kind) !BasicBlock.Id {
    var found: ?BasicBlock.Id = null;
    for (cfg.successorsOf(from)) |edge| {
        if (edge.kind != kind) continue;
        if (found != null) return error.AmbiguousEdge;
        found = edge.dest;
    }
    return found orelse error.NoSuchEdge;
}

/// First block of a container's body, i.e. the entry block's successor.
fn bodyOf(cfg: *const Cfg, container: Container.Id) !BasicBlock.Id {
    return succ(cfg, cfg.getContainer(container).entry, .normal);
}

fn expectKinds(cfg: *const Cfg, from: BasicBlock.Id, expected: []const Edge.Kind) !void {
    const edges = cfg.successorsOf(from);
    try t.expectEqual(expected.len, edges.len);
    for (expected, edges) |kind, edge| try t.expectEqual(kind, edge.kind);
}

fn expectInstructions(cfg: *const Cfg, id: BasicBlock.Id, expected: []const Instruction.Kind) !void {
    const instructions = cfg.instructionsOf(id);
    try t.expectEqual(expected.len, instructions.len);
    for (expected, 0..) |kind, i| try t.expectEqual(kind, instructions.get(i).kind);
}

test "a straight-line function is entry -> body -> exit" {
    var semantic = try buildCfg("fn f() void { g(); }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    try t.expectEqual(1, cfg.containers.len);
    try t.expectEqual(3, cfg.len());

    const container = cfg.getContainer(.from(0));
    try t.expect(container.flags.c_fn);
    try t.expect(container.symbol != .none);

    const body = try bodyOf(cfg, .from(0));
    try expectInstructions(cfg, body, &.{.statement});
    try t.expectEqual(container.exit, try succ(cfg, body, .normal));
    try t.expectEqual(Terminator.Kind.exit, cfg.getBlock(container.exit).terminator.kind);
    try t.expectEqual(0, cfg.successorsOf(container.exit).len);
}

test "if without an else falls through to the join block" {
    var semantic = try buildCfg("fn f(a: bool) void { if (a) { g(); } h(); }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const cond = try bodyOf(cfg, .from(0));
    try t.expectEqual(Terminator.Kind.branch, cfg.getBlock(cond).terminator.kind);
    try expectKinds(cfg, cond, &.{ .true_branch, .false_branch });
    try expectInstructions(cfg, cond, &.{ .statement, .condition });

    const then_blk = try succ(cfg, cond, .true_branch);
    const join = try succ(cfg, cond, .false_branch);
    try t.expectEqual(join, try succ(cfg, then_blk, .normal));
    try t.expectEqual(2, cfg.predecessorsOf(join).len);
}

test "if/else joins both arms" {
    var semantic = try buildCfg("fn f(a: bool) void { if (a) { g(); } else { h(); } }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const cond = try bodyOf(cfg, .from(0));
    const then_blk = try succ(cfg, cond, .true_branch);
    const else_blk = try succ(cfg, cond, .false_branch);
    try t.expect(then_blk != else_blk);

    const join = try succ(cfg, then_blk, .normal);
    try t.expectEqual(join, try succ(cfg, else_blk, .normal));
    try t.expectEqual(cfg.getContainer(.from(0)).exit, try succ(cfg, join, .normal));
}

test "continue targets a while loop's continue block, not its header" {
    const src = "fn f(n: u32) void { var i: u32 = 0; while (i < n) : (i += 1) { if (i == 3) continue; if (i == 4) break; } }";
    var semantic = try buildCfg(src);
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const pre = try bodyOf(cfg, .from(0));
    const header = try succ(cfg, pre, .normal);
    try t.expect(cfg.getBlock(header).flags.b_loop_header);

    const body = try succ(cfg, header, .true_branch);
    const exit = try succ(cfg, header, .false_branch);

    // `continue` lands in the cont block, which holds `i += 1` and closes the loop.
    const cont = try succ(cfg, body, .true_branch);
    try t.expectEqual(Terminator.Kind.@"continue", cfg.getBlock(cont).terminator.kind);
    const cont_blk = try succ(cfg, cont, .jump);
    try expectInstructions(cfg, cont_blk, &.{.continue_expr});
    try t.expectEqual(header, try succ(cfg, cont_blk, .back));

    // `break` skips the cont block entirely.
    const after_continue = try succ(cfg, body, .false_branch);
    const brk = try succ(cfg, after_continue, .true_branch);
    try t.expectEqual(Terminator.Kind.@"break", cfg.getBlock(brk).terminator.kind);
    try t.expectEqual(exit, try succ(cfg, brk, .jump));

    // and the body falls through to the cont block.
    try t.expectEqual(cont_blk, try succ(cfg, try succ(cfg, after_continue, .false_branch), .normal));
}

test "break bypasses a loop's else block" {
    const src = "fn f(items: []const u32) u32 { for (items) |it| { if (it == 1) break; } else { return 0; } return 1; }";
    var semantic = try buildCfg(src);
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const header = try succ(cfg, try bodyOf(cfg, .from(0)), .normal);
    const body = try succ(cfg, header, .true_branch);
    const else_blk = try succ(cfg, header, .false_branch);
    try t.expectEqual(Terminator.Kind.@"return", cfg.getBlock(else_blk).terminator.kind);

    const brk = try succ(cfg, body, .true_branch);
    const exit = try succ(cfg, brk, .jump);
    try t.expect(exit != else_blk);
    // the loop exit is only reachable from the `break`; `else` returns.
    try t.expectEqualSlices(BasicBlock.Id, &.{brk}, cfg.predecessorsOf(exit));
}

test "while ... else |e| is entered on an error edge" {
    var semantic = try buildCfg("fn f() void { while (it.next()) |v| { g(v); } else |e| { h(e); } }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const header = try succ(cfg, try bodyOf(cfg, .from(0)), .normal);
    try expectKinds(cfg, header, &.{ .true_branch, .@"error" });
    try t.expect(cfg.getBlock(try succ(cfg, header, .@"error")).flags.b_error);
}

test "labeled break and continue target the named loop" {
    var semantic = try buildCfg("fn f() void { outer: while (a) { while (b) { continue :outer; } } }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const outer = try succ(cfg, try bodyOf(cfg, .from(0)), .normal);
    const outer_body = try succ(cfg, outer, .true_branch);
    const inner = try succ(cfg, outer_body, .normal);
    try t.expect(cfg.getBlock(inner).flags.b_loop_header);
    const cont = try succ(cfg, inner, .true_branch);
    try t.expectEqual(Terminator.Kind.@"continue", cfg.getBlock(cont).terminator.kind);

    // the jump leaves the inner loop and lands in the outer loop's cont block.
    const target = try succ(cfg, cont, .jump);
    try t.expectEqual(outer, try succ(cfg, target, .back));
}

test "a switch has one block per prong and no fallthrough" {
    var semantic = try buildCfg("fn f(x: u32) void { switch (x) { 0 => g(), 1 => h(), else => {} } }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const dispatch = try bodyOf(cfg, .from(0));
    try t.expectEqual(Terminator.Kind.@"switch", cfg.getBlock(dispatch).terminator.kind);
    try expectKinds(cfg, dispatch, &.{ .true_branch, .true_branch, .true_branch });

    const join = try succ(cfg, cfg.successorsOf(dispatch)[0].dest, .normal);
    for (cfg.successorsOf(dispatch)) |edge| {
        try t.expectEqual(join, try succ(cfg, edge.dest, .normal));
    }
}

test "a switch without an else prong gets a conservative fallthrough edge" {
    var semantic = try buildCfg("fn f(x: u32) void { switch (x) { 0 => g(), 1 => h() } }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const dispatch = try bodyOf(cfg, .from(0));
    try expectKinds(cfg, dispatch, &.{ .true_branch, .true_branch, .false_branch });
    const join = try succ(cfg, dispatch, .false_branch);
    try t.expectEqual(3, cfg.predecessorsOf(join).len);
}

test "a labeled switch's dispatch block is a loop header" {
    var semantic = try buildCfg("fn f(x: u32) void { lbl: switch (x) { 0 => continue :lbl 1, 1 => {}, else => {} } }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    // a labeled dispatch gets its own block, so it holds nothing but the operand.
    const dispatch = try succ(cfg, try bodyOf(cfg, .from(0)), .normal);
    try t.expect(cfg.getBlock(dispatch).flags.b_loop_header);
    try expectInstructions(cfg, dispatch, &.{.condition});

    const redispatch = cfg.successorsOf(dispatch)[0].dest;
    try t.expectEqual(Terminator.Kind.@"continue", cfg.getBlock(redispatch).terminator.kind);
    try t.expectEqual(dispatch, try succ(cfg, redispatch, .back));
}

test "an unlabeled break inside a switch targets the enclosing loop" {
    var semantic = try buildCfg("fn f() void { while (a) { switch (x) { 0 => break, else => {} } } }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const header = try succ(cfg, try bodyOf(cfg, .from(0)), .normal);
    const loop_exit = try succ(cfg, header, .false_branch);
    const dispatch = try succ(cfg, header, .true_branch);
    const brk = cfg.successorsOf(dispatch)[0].dest;

    try t.expectEqual(Terminator.Kind.@"break", cfg.getBlock(brk).terminator.kind);
    try t.expectEqual(loop_exit, try succ(cfg, brk, .jump));
}

test "a labeled block yields through its join block" {
    var semantic = try buildCfg("fn f(a: bool) u32 { const x = blk: { if (a) break :blk 1; break :blk 2; }; return x; }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const cond = try bodyOf(cfg, .from(0));
    const first = try succ(cfg, try succ(cfg, cond, .true_branch), .jump);
    const second = try succ(cfg, try succ(cfg, cond, .false_branch), .jump);
    try t.expectEqual(first, second);
    try t.expectEqual(Terminator.Kind.@"return", cfg.getBlock(first).terminator.kind);
}

test "try splits its block once per occurrence" {
    var semantic = try buildCfg("fn f() !void { g(try a(), try b()); }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const exit = cfg.getContainer(.from(0)).exit;
    const first = try bodyOf(cfg, .from(0));
    try t.expectEqual(Terminator.Kind.branch, cfg.getBlock(first).terminator.kind);
    try t.expectEqual(exit, try succ(cfg, first, .@"error"));

    const second = try succ(cfg, first, .normal);
    try t.expectEqual(exit, try succ(cfg, second, .@"error"));
    try t.expectEqual(exit, try succ(cfg, try succ(cfg, second, .normal), .normal));
}

test "catch handlers are on an error edge" {
    var semantic = try buildCfg("fn f(a: anyerror!u32) u32 { return a catch 0; }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const lhs = try bodyOf(cfg, .from(0));
    try expectKinds(cfg, lhs, &.{ .@"error", .normal });

    const handler = try succ(cfg, lhs, .@"error");
    try t.expect(cfg.getBlock(handler).flags.b_error);
    try t.expectEqual(try succ(cfg, lhs, .normal), try succ(cfg, handler, .normal));
}

test "orelse branches on the null case" {
    var semantic = try buildCfg("fn f(a: ?u32) u32 { return a orelse 0; }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const lhs = try bodyOf(cfg, .from(0));
    try expectKinds(cfg, lhs, &.{ .false_branch, .true_branch });
    try t.expectEqual(try succ(cfg, lhs, .true_branch), try succ(cfg, try succ(cfg, lhs, .false_branch), .normal));
}

test "errdefer only runs on error paths, in reverse declaration order" {
    const src = "fn f(x: bool) !void { defer a(); defer b(); errdefer c(); if (x) return; try d(); }";
    var semantic = try buildCfg(src);
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const exit = cfg.getContainer(.from(0)).exit;
    const cond = try bodyOf(cfg, .from(0));

    // `return` runs the two defers, skipping the errdefer.
    const ret = try succ(cfg, cond, .true_branch);
    const ret_chain = try succ(cfg, ret, .cleanup);
    try t.expect(cfg.getBlock(ret_chain).flags.b_cleanup);
    try t.expect(!cfg.getBlock(ret_chain).flags.b_error);
    try expectInstructions(cfg, ret_chain, &.{ .cleanup, .cleanup });
    try t.expectEqual(exit, try succ(cfg, ret_chain, .normal));

    // `try`'s error edge runs the errdefer as well.
    const @"try" = try succ(cfg, cond, .false_branch);
    const err_chain = try succ(cfg, @"try", .cleanup);
    try t.expect(cfg.getBlock(err_chain).flags.b_error);
    try expectInstructions(cfg, err_chain, &.{ .cleanup, .cleanup, .cleanup });
    try t.expectEqual(exit, try succ(cfg, err_chain, .@"error"));

    // reverse declaration order: errdefer c, defer b, defer a
    const instructions = cfg.instructionsOf(err_chain);
    const nodes = instructions.items(.node);
    try t.expect(@intFromEnum(nodes[0]) > @intFromEnum(nodes[1]));
    try t.expect(@intFromEnum(nodes[1]) > @intFromEnum(nodes[2]));

    // and the fallthrough off the end of the body runs the defers too.
    const fallthrough = try succ(cfg, try succ(cfg, @"try", .normal), .cleanup);
    try expectInstructions(cfg, fallthrough, &.{ .cleanup, .cleanup });
}

test "return error.Foo runs errdefer chains" {
    var semantic = try buildCfg("fn f(x: bool) !void { errdefer a(); if (x) return error.Foo; return; }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const cond = try bodyOf(cfg, .from(0));
    const err_return = try succ(cfg, cond, .true_branch);
    const chain = try succ(cfg, err_return, .cleanup);
    try t.expect(cfg.getBlock(chain).flags.b_error);
    try expectInstructions(cfg, chain, &.{.cleanup});

    // a plain `return` has nothing to run, so it goes straight to the exit.
    const plain_return = try succ(cfg, cond, .false_branch);
    try t.expectEqual(cfg.getContainer(.from(0)).exit, try succ(cfg, plain_return, .normal));
}

test "sibling scopes do not share memoized cleanup chains" {
    const src = "fn f(x: bool) !void { { defer a(); if (x) return; } { defer b(); if (x) return; } }";
    var semantic = try buildCfg(src);
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const first_cond = try bodyOf(cfg, .from(0));
    const first_chain = try succ(cfg, try succ(cfg, first_cond, .true_branch), .cleanup);

    const second_cond = try succ(cfg, try succ(cfg, first_cond, .false_branch), .cleanup);
    const second_chain = try succ(cfg, try succ(cfg, second_cond, .true_branch), .cleanup);

    try t.expect(first_chain != second_chain);
    const first_node = cfg.instructionsOf(first_chain).items(.node)[0];
    const second_node = cfg.instructionsOf(second_chain).items(.node)[0];
    try t.expect(first_node != second_node);
}

test "unreachable and @panic terminate a block" {
    for ([_][:0]const u8{
        "fn f() void { unreachable; }",
        "fn f() void { @panic(\"boom\"); }",
    }) |src| {
        var semantic = try buildCfg(src);
        defer semantic.deinit();
        const cfg = &semantic.cfg;

        const container = cfg.getContainer(.from(0));
        const body = try bodyOf(cfg, .from(0));
        try t.expectEqual(Terminator.Kind.@"unreachable", cfg.getBlock(body).terminator.kind);
        // the only way out is the (never-taken) unreachable edge, so the exit
        // block stays forward-unreachable.
        try expectKinds(cfg, body, &.{.@"unreachable"});
        try t.expectEqual(container.exit, try succ(cfg, body, .@"unreachable"));
        try t.expect(cfg.getBlock(container.exit).flags.b_unreachable);
    }
}

test "@breakpoint does not terminate a block" {
    var semantic = try buildCfg("fn f() void { @breakpoint(); g(); }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const body = try bodyOf(cfg, .from(0));
    try expectInstructions(cfg, body, &.{ .statement, .statement });
    try t.expectEqual(cfg.getContainer(.from(0)).exit, try succ(cfg, body, .normal));
}

test "calls to a same-file noreturn function terminate a block" {
    // Container decls are order independent, so the callee being declared after
    // its call site must not change the graph.
    const sources = [_][:0]const u8{
        "fn die() noreturn { while (true) {} }\nfn f() void { die(); g(); }",
        "fn f() void { die(); g(); }\nfn die() noreturn { while (true) {} }",
    };
    for (sources, [_]u32{ 1, 0 }) |src, container| {
        var semantic = try buildCfg(src);
        defer semantic.deinit();
        const cfg = &semantic.cfg;

        const body = try bodyOf(cfg, .from(container));
        try t.expectEqual(Terminator.Kind.@"unreachable", cfg.getBlock(body).terminator.kind);
        try expectKinds(cfg, body, &.{.@"unreachable"});
        try t.expect(!cfg.getBlock(body).flags.b_unreachable);
        // the call, and nothing after it
        try expectInstructions(cfg, body, &.{.statement});

        // `g()` lands in a block nothing reaches.
        var dead: ?BasicBlock.Id = null;
        for (0..cfg.len()) |i| {
            const id: BasicBlock.Id = .from(i);
            if (!cfg.getBlock(id).flags.b_unreachable) continue;
            if (cfg.instructionsOf(id).len == 0) continue;
            try t.expect(dead == null);
            dead = id;
        }
        try expectInstructions(cfg, dead orelse return error.NoDeadBlock, &.{.statement});
    }
}

test "dead code after a noreturn call still moves out when the call ends a block" {
    // The call is lowered into a block that is empty at the time (the `if`
    // split it off), so the split point sits exactly at the block's first
    // instruction.
    const src = "fn f(x: bool) void { die(if (x) 1 else 2); g(); }\nfn die(_: u32) noreturn { while (true) {} }";
    var semantic = try buildCfg(src);
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    var dead: u32 = 0;
    for (0..cfg.len()) |i| {
        const id: BasicBlock.Id = .from(i);
        const block = cfg.getBlock(id);
        if (cfg.instructionsOf(id).len == 0) continue;
        // no reachable block may hold instructions past an `unreachable` terminator
        try t.expect(block.flags.b_unreachable or block.terminator.kind != .@"unreachable");
        if (block.flags.b_unreachable) dead += 1;
    }
    try t.expectEqual(1, dead);
}

test "comptime does not leak from a decl initializer into a nested fn" {
    var semantic = try buildCfg("const S = struct { fn bar() void { g(); } };\ncomptime { g(); }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    for (0..cfg.containers.len) |i| {
        const is_fn = cfg.getContainer(.from(i)).flags.c_fn;
        for (0..cfg.len()) |b| {
            const block = cfg.getBlock(.from(b));
            if (block.container.int() != i) continue;
            try t.expectEqual(!is_fn, block.flags.b_comptime);
        }
    }
}

test "dead code after a return is marked unreachable" {
    var semantic = try buildCfg("fn f() void { return; g(); }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const body = try bodyOf(cfg, .from(0));
    try t.expect(!cfg.getBlock(body).flags.b_unreachable);

    var dead: u32 = 0;
    for (0..cfg.len()) |i| {
        if (cfg.getBlock(.from(i)).flags.b_unreachable) dead += 1;
    }
    try t.expectEqual(1, dead);
}

test "nested functions get their own containers" {
    var semantic = try buildCfg("fn outer() void { const S = struct { fn inner() void { g(); } }; S.inner(); }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    try t.expectEqual(2, cfg.containers.len);
    const outer = cfg.getContainer(.from(0));
    const inner = cfg.getContainer(.from(1));
    try t.expect(outer.flags.c_fn and inner.flags.c_fn);

    const containers = cfg.blocks.items(.container);
    try t.expectEqual(Container.Id.from(0), containers[outer.entry.into(usize)]);
    try t.expectEqual(Container.Id.from(1), containers[inner.entry.into(usize)]);

    // the outer block is split around the nested container so instruction
    // ranges stay contiguous.
    for (0..cfg.len()) |i| {
        const block = cfg.getBlock(.from(i));
        const range = block.instructions;
        try t.expect(range.start.int() + range.len <= cfg.instructions.len);
    }
}

test "test and comptime blocks get their own containers" {
    var semantic = try buildCfg("test \"t\" { g(); }\ncomptime { var x = 1; x += 1; }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    try t.expectEqual(2, cfg.containers.len);
    try t.expect(cfg.getContainer(.from(0)).flags.c_test);

    const comptime_container = cfg.getContainer(.from(1));
    try t.expect(comptime_container.flags.c_comptime);
    try t.expect(cfg.getBlock(try bodyOf(cfg, .from(1))).flags.b_comptime);
    try t.expect(!cfg.getBlock(try bodyOf(cfg, .from(0))).flags.b_comptime);
}

test "container-level decl initializers get their own container" {
    var semantic = try buildCfg("const x = blk: { break :blk 1; };");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    try t.expectEqual(1, cfg.containers.len);
    try t.expect(cfg.getContainer(.from(0)).flags.c_decl);
}

test "inline loops keep their shape and are marked comptime" {
    var semantic = try buildCfg("fn f() void { inline for (.{1}) |i| { g(i); } }");
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    const header = try succ(cfg, try bodyOf(cfg, .from(0)), .normal);
    try t.expect(cfg.getBlock(header).flags.b_loop_header);
    try t.expect(cfg.getBlock(header).flags.b_comptime);
    try expectKinds(cfg, header, &.{ .true_branch, .false_branch });
}

test "the CFG is not built unless it is enabled" {
    var builder: Semantic.Builder = .init(t.allocator);
    defer builder.deinit();

    var result = try builder.build("fn f(a: bool) void { if (a) return; while (a) {} }");
    defer result.deinit();

    try t.expectEqual(0, result.value.cfg.len());
    try t.expectEqual(0, result.value.cfg.containers.len);
    try t.expectEqual(0, result.value.cfg.instructions.len);
    try t.expectEqual(0, result.value.cfg.successors.items.len);
    // the node -> block map is never allocated
    try t.expectEqual(0, result.value.node_links.blocks.items.len);
}

test "finalize invariants hold over large real files" {
    for ([_][:0]const u8{
        @embedFile("Builder.zig"),
        @embedFile("../Cfg.zig"),
        @embedFile("../../visit/walk.zig"),
        @embedFile("../../linter/rules/useless_error_return.zig"),
        @embedFile("../../linter/linter.zig"),
        @embedFile("../../util/bitflags.zig"),
    }) |src| try expectFinalizeInvariants(src);
}

fn expectFinalizeInvariants(src: [:0]const u8) !void {
    var semantic = try buildCfg(src);
    defer semantic.deinit();
    const cfg = &semantic.cfg;

    try t.expect(cfg.containers.len > 0);
    try t.expectEqual(cfg.len(), cfg.successors.items.len);
    try t.expectEqual(cfg.len(), cfg.predecessors.items.len);

    for (0..cfg.len()) |i| {
        const id: BasicBlock.Id = .from(i);
        const block = cfg.getBlock(id);
        try t.expect(block.container.int() < cfg.containers.len);
        try t.expect(block.instructions.start.int() + block.instructions.len <= cfg.instructions.len);
        // `.exit` is the only successor-less terminator.
        switch (block.terminator.kind) {
            .exit => try t.expectEqual(0, cfg.successorsOf(id).len),
            else => try t.expect(cfg.successorsOf(id).len > 0),
        }
        for (cfg.successorsOf(id)) |edge| try t.expect(edge.dest.int() < cfg.len());
    }
}
