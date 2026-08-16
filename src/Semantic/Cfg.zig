//! Control flow graph for a single source file.
//!
//! Blocks are flat and globally id'd across the file, like `Scope.Tree`. Each
//! belongs to exactly one `Container` — a function body, `test` block,
//! `comptime` block, or top-level decl initializer.
//!
//! Explicit successor edge lists are the single source of truth. Predecessors
//! are derived by `finalize`, which must run exactly once after construction.
//!
//! ## Known limitations
//! - `bool_and`/`bool_or` short-circuit branches, `.?` panic edges, and
//!   cross-file `noreturn` inference are not modeled.
//! - zlint does not have types, so `return someExpr` is always treated as a
//!   non-error return. Only a syntactic `return error.Foo` runs `errdefer`
//!   chains.

const Cfg = @This();

/// All basic blocks in the file, indexed by `BasicBlock.Id`.
blocks: BasicBlock.List.Slice,
/// Outgoing edges, indexed by `BasicBlock.Id`. Parallel to `blocks`.
///
/// TODO: store a list of ranges into an `edges` list
///
/// ### Invariants:
/// - `successors.items.len == blocks.len`
/// - Every `Edge.dest` is `< blocks.len`
/// - A block has no successors if and only if it terminates with `.exit`
successors: std.ArrayList(Edge.List),
/// Incoming edges, indexed by `BasicBlock.Id`. Derived by `finalize`; empty
/// before it runs.
predecessors: std.ArrayList(BlockIdList),
/// Flat instruction arena. `BasicBlock.instructions` indexes into this.
instructions: Instruction.List.Slice,
/// One per control-flow container (fn body, test, comptime block, decl
/// initializer).
containers: Container.List.Slice,

pub const empty: Cfg = .{
    .blocks = .empty,
    .successors = .empty,
    .predecessors = .empty,
    .instructions = .empty,
    .containers = .empty,
};

pub const BlockIdList = std.ArrayList(BasicBlock.Id);

pub fn deinit(self: *Cfg, alloc: Allocator) void {
    for (self.successors.items) |*e| e.deinit(alloc);
    self.successors.deinit(alloc);

    for (self.predecessors.items) |*p| p.deinit(alloc);
    self.predecessors.deinit(alloc);

    self.blocks.deinit(alloc);
    self.instructions.deinit(alloc);
    self.containers.deinit(alloc);
}

/// Number of basic blocks in the file.
pub fn len(self: *const Cfg) usize {
    return self.blocks.len;
}

/// Get all properties of a block by ID.
///
/// Avoid this when possible. Prefer using property slices for better cache
/// locality.
pub fn getBlock(self: *const Cfg, id: BasicBlock.Id) BasicBlock {
    return self.blocks.get(id.into(usize));
}

pub fn getContainer(self: *const Cfg, id: Container.Id) Container {
    return self.containers.get(id.into(usize));
}

/// Outgoing edges of a block.
pub fn successorsOf(self: *const Cfg, id: BasicBlock.Id) []const Edge {
    return self.successors.items[id.into(usize)].items;
}

/// Incoming edges of a block. Empty until `Draft.finalize` has run.
pub fn predecessorsOf(self: *const Cfg, id: BasicBlock.Id) []const BasicBlock.Id {
    return self.predecessors.items[id.into(usize)].items;
}

/// A block's instructions, in evaluation order.
pub fn instructionsOf(self: *const Cfg, id: BasicBlock.Id) InstructionSlice {
    const range = self.blocks.items(.instructions)[id.into(usize)];
    return .{ .arena = self.instructions, .start = range.start.int(), .len = range.len };
}

/// View into a contiguous run of `Cfg.instructions`.
pub const InstructionSlice = struct {
    arena: Instruction.List.Slice,
    start: u32,
    len: u32,

    pub fn get(self: InstructionSlice, i: usize) Instruction {
        assert(i < self.len, "Instruction index out of bounds ({d} >= {d})", .{ i, self.len });
        return self.arena.get(self.start + i);
    }

    pub fn items(
        self: InstructionSlice,
        comptime field: Instruction.List.Field,
    ) []const @FieldType(Instruction, @tagName(field)) {
        return self.arena.items(field)[self.start..][0..self.len];
    }
};

/// Depth-first walk from `start`, never leaving `start`'s container.
/// Caller owns the returned iterator; `deinit` it.
pub fn dfs(
    self: *const Cfg,
    alloc: Allocator,
    start: BasicBlock.Id,
) Allocator.Error!Dfs {
    assert(
        start.int() < self.blocks.len,
        "Block id out of bounds (id {d} >= {d})",
        .{ start.int(), self.blocks.len },
    );

    var visited: std.DynamicBitSetUnmanaged = try .initEmpty(alloc, self.blocks.len);
    errdefer visited.deinit(alloc);

    var stack: std.ArrayList(BasicBlock.Id) = .empty;
    errdefer stack.deinit(alloc);
    try stack.append(alloc, start);

    return .{ .cfg = self, .stack = stack, .visited = visited, .alloc = alloc };
}

/// Mutable handle to a single block. Invalidated by `addBlock`.
pub const BlockRef = struct {
    id: BasicBlock.Id,
    container: *Container.Id,
    node: *NodeIndex,
    instructions: *Instruction.Range,
    terminator: *Terminator,
    flags: *BasicBlock.Flags,
};

pub const BasicBlock = struct {
    /// The control-flow container this block belongs to.
    container: Container.Id,
    /// AST node that created this block. `.root` for synthetic entry/exit blocks.
    node: NodeIndex,
    /// Range into `Cfg.instructions`. Instructions are in evaluation order.
    instructions: Instruction.Range,
    terminator: Terminator,
    flags: Flags,

    /// Uniquely identifies a basic block within a source file.
    pub const Id = NominalId(u32);
    pub const List = std.MultiArrayList(BasicBlock);

    pub const Flags = packed struct(u8) {
        /// Container entry block.
        b_entry: bool = false,
        /// Container exit block. Terminator is always `.exit`.
        b_exit: bool = false,
        /// Holds a lowered `defer`/`errdefer` body.
        b_cleanup: bool = false,
        /// Only reachable via an error edge.
        b_error: bool = false,
        /// Target of a back edge.
        b_loop_header: bool = false,
        /// Lies inside a `comptime` region (or an `inline` loop / `inline` prong).
        b_comptime: bool = false,
        /// Not reachable from its container's entry. Set by `finalize`.
        b_unreachable: bool = false,
        // Padding
        _: u1 = 0,

        const BitflagsMixin = util.Bitflags(Flags);
        pub const Flag = BitflagsMixin.Flag;
        pub const Repr = BitflagsMixin.Repr;
        pub const empty = BitflagsMixin.empty;
        pub const all = BitflagsMixin.all;
        pub const isEmpty = BitflagsMixin.isEmpty;
        pub const intersects = BitflagsMixin.intersects;
        pub const contains = BitflagsMixin.contains;
        pub const merge = BitflagsMixin.merge;
        pub const set = BitflagsMixin.set;
        pub const not = BitflagsMixin.not;
        pub const eql = BitflagsMixin.eql;
        pub const repr = BitflagsMixin.repr;
        pub const format = BitflagsMixin.format;
        pub const jsonStringify = BitflagsMixin.jsonStringify;
    };
};

/// Describes why a block ends. Edges — not this — are the source of truth for
/// successors; this is descriptive metadata for rules.
pub const Terminator = struct {
    kind: Kind,
    /// The `return`/`break`/`continue`/`unreachable`/branch node. `.root` when
    /// the block simply falls through.
    node: NodeIndex = .root,

    pub const Kind = enum(u8) {
        /// Unconditional fallthrough. Also the state of an unterminated block
        /// during construction.
        goto,
        /// Two-way branch: `if`, loop header, `orelse`, `catch`, `try`.
        branch,
        /// N-way `switch` dispatch.
        @"switch",
        @"return",
        @"break",
        @"continue",
        /// `unreachable` literal. No successors.
        @"unreachable",
        /// Container exit. No successors.
        exit,

        pub const undetermined: Kind = .goto;
    };
};

pub const Edge = struct {
    dest: BasicBlock.Id,

    kind: Kind,
    pub const Id = NominalId(u32);
    pub const List = std.ArrayList(Edge);

    // Uses a compact representation to encode edge kinds + flags.
    // Representation:
    //
    //     u0cj_00b0
    //
    //  * `u` - unreachable
    //  * `c` - cleanup
    //  * `j` - jump
    //  * `b` - branch
    pub const Kind = enum(u8) {
        /// Unconditional fallthrough or join.
        normal = 0b0000_0000,

        /// Condition failed / optional was null.
        false_branch = 0b0000_0010,
        /// Condition held / optional was non-null / error union was a value.
        /// Also used for a `switch` prong being selected.
        true_branch = 0b0000_0011,

        // jumps
        /// loopback (continue, bottom of a loop, etc)
        back = 0b0001_0000,
        /// `break` out of a switch/loop/block, or `continue` to a loop's cont
        /// block, with or without a label.
        jump = 0b0001_0100,
        /// `return` from a function
        @"return" = 0b0001_1000,
        /// Error propagation: `try` failure, `catch` handler,
        /// `while ... else |e|`.
        @"error" = 0b0001_1100,
        // note: error and cleanup-on-error paths share `0000_1100` in case we
        // need them grouped at some point

        // cleanup
        /// Edge into a `defer`/`errdefer` chain. Whether the chain is on an
        /// error path is recorded on the target block's `b_error` flag.
        cleanup = 0b0010_0000,

        /// Explicitly unreachable code, e.g. `unreachable`, `@panic`,
        /// `noreturn` functions, etc.
        @"unreachable" = 0b1000_0000,
        /// Implicitly unreachable code
        unreachable_implicit = 0b1100_0000,

        // zig fmt: off
        const branch_mask: u8      = 0b0000_0010;
        const jump_mask: u8        = 0b0001_0000;
        const cleanup_mask: u8     = 0b0010_0000;
        const unreachable_mask: u8 = 0b1000_0000;
        // zig fmt: on

        pub inline fn isBranch(self: Kind) bool {
            return @intFromEnum(self) & branch_mask != 0;
        }

        pub inline fn isCleanup(self: Kind) bool {
            return @intFromEnum(self) & cleanup_mask != 0;
        }

        pub inline fn isJump(self: Kind) bool {
            return @intFromEnum(self) & jump_mask != 0;
        }

        pub inline fn isUnreachable(self: Kind) bool {
            return @intFromEnum(self) & unreachable_mask != 0;
        }
    };
};

pub const Instruction = struct {
    /// AST node this was lowered from.
    node: NodeIndex,
    kind: Kind,

    /// Uniquely identifies an instruction within a source file.
    pub const Id = NominalId(u32);
    pub const List = std.MultiArrayList(Instruction);
    /// A contiguous run of instructions within `Cfg.instructions`.
    pub const Range = struct {
        start: Instruction.Id,
        len: u32,
        pub const empty: Range = .{ .start = .root, .len = 0 };
    };

    pub const Kind = enum(u8) {
        /// A statement or expression evaluated for effect.
        statement,
        /// The operand of a branch (`if` cond, loop cond, `switch` operand,
        /// `orelse`/`catch` lhs, `try` operand).
        condition,
        /// A loop's `: (i += 1)` continue expression.
        continue_expr,
        /// A lowered `defer`/`errdefer` body.
        cleanup,
    };
};

pub const Container = struct {
    /// The `fn_decl` / `test_decl` / `@"comptime"` / top-level decl node.
    node: NodeIndex,
    /// The function or test symbol, when there is one.
    symbol: Symbol.Id.Optional = .none,
    entry: BasicBlock.Id,
    exit: BasicBlock.Id,
    flags: Flags,

    /// Uniquely identifies a control-flow container within a source file.
    pub const Id = NominalId(u32);
    pub const List = std.MultiArrayList(Container);

    pub const Flags = packed struct(u8) {
        c_fn: bool = false,
        c_test: bool = false,
        c_comptime: bool = false,
        /// Top-level decl initializer, e.g. `const x = blk: { ... };`
        c_decl: bool = false,
        // Padding
        _: u4 = 0,

        const BitflagsMixin = util.Bitflags(Flags);
        pub const Flag = BitflagsMixin.Flag;
        pub const Repr = BitflagsMixin.Repr;
        pub const empty = BitflagsMixin.empty;
        pub const all = BitflagsMixin.all;
        pub const isEmpty = BitflagsMixin.isEmpty;
        pub const intersects = BitflagsMixin.intersects;
        pub const contains = BitflagsMixin.contains;
        pub const merge = BitflagsMixin.merge;
        pub const set = BitflagsMixin.set;
        pub const not = BitflagsMixin.not;
        pub const eql = BitflagsMixin.eql;
        pub const repr = BitflagsMixin.repr;
        pub const format = BitflagsMixin.format;
        pub const jsonStringify = BitflagsMixin.jsonStringify;
    };
};

/// Depth-first block iterator. Yields each reachable block in `start`'s
/// container exactly once, starting with `start`.
pub const Dfs = struct {
    cfg: *const Cfg,
    stack: std.ArrayList(BasicBlock.Id),
    visited: std.DynamicBitSetUnmanaged,
    alloc: Allocator,

    pub fn next(self: *Dfs) Allocator.Error!?BasicBlock.Id {
        const containers = self.cfg.blocks.items(.container);

        while (self.stack.pop()) |id| {
            const idx = id.into(usize);
            if (self.visited.isSet(idx)) continue;
            self.visited.set(idx);

            const owner = containers[idx];
            for (self.cfg.successorsOf(id)) |edge| {
                if (edge.kind.isUnreachable()) continue;
                const dest = edge.dest.into(usize);
                if (containers[dest] != owner or self.visited.isSet(dest)) continue;
                try self.stack.append(self.alloc, edge.dest);
            }

            return id;
        }

        return null;
    }

    pub fn deinit(self: *Dfs) void {
        self.stack.deinit(self.alloc);
        self.visited.deinit(self.alloc);
    }
};

pub const Draft = @import("Cfg/Draft.zig");
pub const Builder = @import("Cfg/Builder.zig");
pub const dot = @import("Cfg/dot.zig");

const std = @import("std");
const util = @import("util");
const _ast = @import("ast.zig");

const Allocator = std.mem.Allocator;
const NodeIndex = _ast.NodeIndex;
const Symbol = @import("Symbol.zig");
const NominalId = util.NominalId;

const assert = util.assert;

const t = std.testing;

test {
    t.refAllDecls(Draft);
    t.refAllDecls(dot);
}

test dfs {
    const alloc = t.allocator;

    var draft: Draft = .empty;
    errdefer draft.deinit(alloc);

    // Blocks may forward-reference a container that has not been added yet.
    const a: Container.Id = .from(0);
    const a_entry = try draft.addBlock(alloc, .{ .container = a, .flags = .{ .b_entry = true } });
    const a_body = try draft.addBlock(alloc, .{ .container = a });
    const a_exit = try draft.addBlock(alloc, .{ .container = a, .flags = .{ .b_exit = true } });

    const b: Container.Id = .from(1);
    const b_entry = try draft.addBlock(alloc, .{ .container = b, .flags = .{ .b_entry = true } });
    const b_exit = try draft.addBlock(alloc, .{ .container = b, .flags = .{ .b_exit = true } });

    _ = try draft.addContainer(alloc, .{
        .node = .root,
        .entry = a_entry,
        .exit = a_exit,
        .flags = .{ .c_fn = true },
    });
    _ = try draft.addContainer(alloc, .{
        .node = .root,
        .entry = b_entry,
        .exit = b_exit,
        .flags = .{ .c_test = true },
    });

    try draft.addEdge(alloc, a_entry, .{ .dest = a_body, .kind = .normal });
    try draft.addEdge(alloc, a_body, .{ .dest = a_exit, .kind = .normal });
    try draft.addEdge(alloc, b_entry, .{ .dest = b_exit, .kind = .normal });
    // an edge leaving `a` must not pull `b`'s blocks into the walk
    try draft.addEdge(alloc, a_body, .{ .dest = b_entry, .kind = .normal });

    var cfg = try draft.finalize(alloc);
    defer cfg.deinit(alloc);

    var it = try cfg.dfs(alloc, a_entry);
    defer it.deinit();

    var seen: BlockIdList = .empty;
    defer seen.deinit(alloc);
    while (try it.next()) |id| try seen.append(alloc, id);

    try t.expectEqualSlices(BasicBlock.Id, &.{ a_entry, a_body, a_exit }, seen.items);
}
