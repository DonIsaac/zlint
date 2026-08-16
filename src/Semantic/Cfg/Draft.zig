const Draft = @This();

/// All basic blocks in the file, indexed by `BasicBlock.Id`.
blocks: BasicBlock.List,
/// Outgoing edges, indexed by `BasicBlock.Id`. Parallel to `blocks`.
///
/// ### Invariants:
/// - `successors.items.len == blocks.len`
/// - Every `Edge.dest` is `< blocks.len`
/// - A block has no successors if and only if it terminates with `.exit`
successors: std.ArrayList(Edge.List),
/// Flat instruction arena. `BasicBlock.instructions` indexes into this.
instructions: Instruction.List,
/// One per control-flow container (fn body, test, comptime block, decl
/// initializer).
containers: Container.List,

pub const empty: Draft = .{
    .blocks = .empty,
    .successors = .empty,
    .instructions = .empty,
    .containers = .empty,
};

pub fn ensureUnusedCapacity(
    self: *Draft,
    allocator: Allocator,
    block_count: u32,
) Allocator.Error!void {
    // Average number of instructions per basic block.
    // TODO: This value is made up. Run experiments and get a better value for it.
    const instructions_per_block = 8;
    const size: usize = block_count;

    try self.blocks.ensureUnusedCapacity(allocator, size);
    try self.successors.ensureUnusedCapacity(allocator, size);
    try self.containers.ensureUnusedCapacity(allocator, size);
    try self.instructions.ensureUnusedCapacity(
        allocator,
        size * instructions_per_block,
    );
}

pub fn deinit(self: *Draft, allocator: Allocator) void {
    for (self.successors.items) |*s| s.deinit(allocator);
    self.successors.deinit(allocator);
    self.blocks.deinit(allocator);
    self.instructions.deinit(allocator);
    self.containers.deinit(allocator);
}

pub const NewBlock = struct {
    /// May forward-reference a container that has not been added yet (i.e.
    /// `Container.Id.from(cfg.containers.items.len)`). Never validated; the
    /// caller must add that container before `finalize` runs.
    container: Container.Id,
    node: Node.Index = .root,
    flags: BasicBlock.Flags = .empty,
    instructions: []const Instruction = &.{},
};

/// Append a new, empty basic block.
///
/// Blocks start out falling through (`.goto`), except container exits, which
/// start out as `.exit`. Use `blockMut` to set the terminator once it is known.
pub fn addBlock(
    self: *Draft,
    alloc: Allocator,
    block: NewBlock,
) Allocator.Error!BasicBlock.Id {
    const id: BasicBlock.Id = .from(self.blocks.len);
    assert(self.blocks.len == self.successors.items.len);

    const prev_instruction_count = self.instructions.len;
    const instructions = try self.addInstructions(alloc, block.instructions);
    errdefer self.instructions.shrinkRetainingCapacity(prev_instruction_count);

    const block_count = self.blocks.len;
    try self.blocks.append(alloc, .{
        .container = block.container,
        .node = block.node,
        .instructions = instructions,
        .terminator = .{ .kind = if (block.flags.b_exit) .exit else .undetermined },
        .flags = block.flags,
    });
    errdefer self.blocks.shrinkRetainingCapacity(block_count);

    try self.successors.append(alloc, .empty);

    return id;
}

/// Insert instructions for a basic block. `instructions` are borrowed and
/// copied into the draft.
fn addInstructions(
    self: *Draft,
    alloc: Allocator,
    instructions: []const Instruction,
) Allocator.Error!Instruction.Range {
    const start: Instruction.Id = .from(self.instructions.len);
    if (instructions.len == 0) {
        // FIXME: this could point to an out of bounds index. Should we
        // unconditionally append a noop instruction here during finalize()?
        return .{ .start = .from(start), .len = 0 };
    }

    try self.instructions.ensureUnusedCapacity(alloc, instructions.len);
    for (instructions) |inst| {
        self.instructions.appendAssumeCapacity(inst);
    }

    return .{ .start = .from(start), .len = @intCast(instructions.len) };
}

/// Append a single instruction to the arena.
pub fn addInstruction(
    self: *Draft,
    alloc: Allocator,
    instruction: Instruction,
) Allocator.Error!Instruction.Id {
    const id: Instruction.Id = .from(self.instructions.len);
    try self.instructions.append(alloc, instruction);
    return id;
}

pub fn addEdge(
    self: *Draft,
    alloc: Allocator,
    from: BasicBlock.Id,
    edge: Edge,
) Allocator.Error!void {
    util.assert(
        from.int() < self.blocks.len,
        "Edge source out of bounds (id {d} >= {d})",
        .{ from.int(), self.blocks.len },
    );
    util.assert(
        edge.dest.int() < self.blocks.len,
        "Edge destination out of bounds (id {d} >= {d})",
        .{ edge.dest.int(), self.blocks.len },
    );

    try self.successors.items[from.int()].append(alloc, edge);
}

/// Outgoing edges of a block.
pub fn successorsOf(self: *const Draft, id: BasicBlock.Id) []const Edge {
    return self.successors.items[id.int()].items;
}

pub fn getContainer(self: *const Draft, id: Container.Id) Container {
    return self.containers.get(id.into(usize));
}

/// Cut `id` in two at instruction `at`. The instructions from `at` onwards, the
/// block's outgoing edges, and its terminator all move to a new block, leaving
/// `id` with the instructions before `at` and no successors.
///
/// `at == range.start` moves everything, leaving `id` empty.
///
/// Returns `null` when `at` falls outside `id`'s instruction range, in which
/// case nothing moves.
pub fn splitBlock(
    self: *Draft,
    alloc: Allocator,
    id: BasicBlock.Id,
    at: Instruction.Id,
) Allocator.Error!?BasicBlock.Id {
    const i = id.into(usize);
    const range = self.blocks.items(.instructions)[i];
    const start = range.start.int();
    if (range.len == 0 or at.int() < start or at.int() >= start + range.len) return null;

    // `addBlock` invalidates handles into `blocks`, so copy first, split after.
    const rest = blk: {
        const blocks = self.blocks.slice();
        const container = blocks.items(.container)[i];
        const node = blocks.items(.node)[i];
        const flags = blocks.items(.flags)[i];
        break :blk try self.addBlock(alloc, .{ .container = container, .node = node, .flags = flags });
    };
    const j = rest.into(usize);

    const blocks = self.blocks.slice();
    blocks.items(.instructions)[i].len = at.int() - start;
    blocks.items(.instructions)[j] = .{ .start = at, .len = start + range.len - at.int() };
    blocks.items(.terminator)[j] = blocks.items(.terminator)[i];
    std.mem.swap(Edge.List, &self.successors.items[i], &self.successors.items[j]);

    return rest;
}

/// Mutable handle to a single block. Invalidated by `addBlock`.
pub fn blockMut(self: *Draft, id: BasicBlock.Id) Cfg.BlockRef {
    const slice = self.blocks.slice();
    const i = id.into(usize);
    return .{
        .id = id,
        .container = &slice.items(.container)[i],
        .node = &slice.items(.node)[i],
        .instructions = &slice.items(.instructions)[i],
        .terminator = &slice.items(.terminator)[i],
        .flags = &slice.items(.flags)[i],
    };
}

pub fn addContainer(
    self: *Draft,
    alloc: Allocator,
    container: Container,
) Allocator.Error!Container.Id {
    util.assert(
        container.entry != container.exit,
        "Containers cannot have the same block for entry and exit {d}",
        .{container.entry},
    );
    const id: Container.Id = .from(self.containers.len);
    try self.containers.append(alloc, container);

    return id;
}

/// Links dead ends to their container exit, builds `predecessors`, and marks
/// `b_unreachable`. Called once, at end of build.
///
/// Moves all draft storage into the returned `Cfg`; the caller must `Cfg.deinit`
/// it. `self` is dead afterwards and must not be used or deinitialized. On
/// error, the draft keeps ownership and must still be deinitialized.
pub fn finalize(self: *Draft, alloc: Allocator) Allocator.Error!Cfg {
    try self.linkUnreachable(alloc);

    const block_count = self.blocks.len;
    util.assert(
        self.successors.items.len == block_count,
        "Cfg.successors is not parallel to Cfg.blocks ({d} != {d})",
        .{ self.successors.items.len, block_count },
    );

    var predecessors: std.ArrayList(Cfg.BlockIdList) = .empty;
    errdefer {
        for (predecessors.items) |*p| p.deinit(alloc);
        predecessors.deinit(alloc);
    }
    try predecessors.ensureTotalCapacityPrecise(alloc, block_count);
    predecessors.appendNTimesAssumeCapacity(.empty, block_count);

    for (self.successors.items, 0..) |edges, i| {
        const from: BasicBlock.Id = .from(i);
        for (edges.items) |edge| {
            const dest = edge.dest.int();
            util.assert(
                dest < block_count,
                "Edge destination out of bounds (id {d} >= {d})",
                .{ dest, block_count },
            );
            try predecessors.items[dest].append(alloc, from);
        }
    }
    try self.markUnreachable(alloc);

    const cfg: Cfg = .{
        .blocks = self.blocks.slice(),
        .successors = self.successors,
        .predecessors = predecessors,
        .instructions = self.instructions.slice(),
        .containers = self.containers.slice(),
    };

    // SAFETY: memory has moved, using this draft post-finalized is illegal behavior.
    self.* = undefined;
    return cfg;
}

/// Give every block that ends in `.@"unreachable"` an `.@"unreachable"` edge to
/// its container's exit, so `.exit` is the only successor-less terminator.
fn linkUnreachable(self: *Draft, alloc: Allocator) Allocator.Error!void {
    const slice = self.blocks.slice();
    const terminators: []const Cfg.Terminator = slice.items(.terminator);
    const block_containers: []const Container.Id = slice.items(.container);
    const exits: []const BasicBlock.Id = self.containers.items(.exit);

    for (0..self.blocks.len) |i| {
        if (terminators[i].kind != .@"unreachable" or self.successors.items[i].items.len > 0) {
            @branchHint(.likely);
            continue;
        }

        const exit: BasicBlock.Id = exits[block_containers[i].int()];
        try self.addEdge(
            alloc,
            .from(i),
            .{ .dest = exit, .kind = .@"unreachable" },
        );
    }
}

/// Mark every block not reachable from its container's entry. `.@"unreachable"`
/// edges are not real control flow, so they are not followed.
fn markUnreachable(self: *Draft, alloc: Allocator) Allocator.Error!void {
    if (self.blocks.len == 0) return;

    var visited = try std.DynamicBitSetUnmanaged.initEmpty(alloc, self.blocks.len);
    defer visited.deinit(alloc);

    var stack_fallback = std.heap.stackFallback(@sizeOf(BasicBlock.Id) * 64, alloc);
    const stack_alloc = stack_fallback.get();
    var stack: std.ArrayList(BasicBlock.Id) = .empty;
    defer stack.deinit(stack_alloc);

    const entries = self.containers.items(.entry);
    const containers: []const Container.Id = self.blocks.items(.container);
    for (0..self.containers.len) |i| {
        const owner: Container.Id = .from(i);

        stack.clearRetainingCapacity();
        try stack.append(stack_alloc, entries[i]);
        while (stack.pop()) |id| {
            const idx = id.into(usize);
            if (visited.isSet(idx)) continue;
            visited.set(idx);
            for (self.successors.items[idx].items) |edge| {
                if (edge.kind.isUnreachable()) continue;
                const dest = edge.dest.into(usize);
                if (containers[dest] != owner or visited.isSet(dest)) continue;
                try stack.append(stack_alloc, edge.dest);
            }
        }
    }

    for (self.blocks.items(.flags), 0..) |*flags, i| {
        if (!visited.isSet(i)) flags.b_unreachable = true;
    }
}

const std = @import("std");
const util = @import("util");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = std.zig.Ast;
const Node = Ast.Node;

const Cfg = @import("../Cfg.zig");
const BasicBlock = Cfg.BasicBlock;
const Edge = Cfg.Edge;
const Container = Cfg.Container;
const Instruction = Cfg.Instruction;

const t = std.testing;

test "implicitly unreachable edges are not followed when marking dead blocks" {
    var draft: Draft = .empty;
    errdefer draft.deinit(t.allocator);

    const entry = try draft.addBlock(t.allocator, .{ .container = .root, .flags = .{ .b_entry = true } });
    const exit = try draft.addBlock(t.allocator, .{ .container = .root, .flags = .{ .b_exit = true } });
    const dead = try draft.addBlock(t.allocator, .{ .container = .root });
    _ = try draft.addContainer(t.allocator, .{
        .node = .root,
        .entry = entry,
        .exit = exit,
        .flags = .{ .c_fn = true },
    });
    try draft.addEdge(t.allocator, entry, .{ .dest = exit, .kind = .normal });
    try draft.addEdge(t.allocator, entry, .{ .dest = dead, .kind = .unreachable_implicit });
    try draft.addEdge(t.allocator, dead, .{ .dest = exit, .kind = .normal });

    var cfg = try draft.finalize(t.allocator);
    defer cfg.deinit(t.allocator);

    try t.expect(cfg.getBlock(dead).flags.b_unreachable);
    try t.expect(!cfg.getBlock(exit).flags.b_unreachable);
}
