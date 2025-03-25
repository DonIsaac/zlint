const Constellation = @This();

allocator: Allocator,
unit_lock: std.Thread.Mutex = .{},
units: dora.AutoDora(BoundSource.Index, BoundSource) = .{},
next_id: atomic.Value(BoundSource.Index) = .init(.first),

pub fn addUninitialized(self: *Constellation, source: Source) BoundSource.Index {
    const index = self.nextId();
    {
        self.unit_lock.lock();
        defer self.unit_lock.unlock();
        // SAFETY: caller is aware `semantic` is not initialized
        try self.units.append(BoundSource{
            .source = source,
            .semantic = undefined,
            .arena = ArenaAllocator.init(self.allocator),
        });
        assert(self.units.items.len == @as(u32, @bitCast(index)));
    }
    return index;
}

inline fn nextId(self: *Constellation) BoundSource.Index {
    return self.next_id.fetchAdd(1, .monotonic);
}

pub const GlobalSymbolId = struct {
    source: BoundSource.Index,
    symbol: Semantic.Symbol.Id,
};

pub const BoundSource = struct {
    /// Bound source where this symbol is defined.
    source: Source,
    arena: ArenaAllocator,
    // semantic: Semantic,
    lock: RwLock = .{},

    semantic: Semantic,
    // state: State = .uninitialized,

    // pub const State = union(enum) {
    //     uninitialized,
    //     unbound: Unbound,
    //     bind: Bound,

    //     pub const Unbound = struct {
    //         ast: std.zig.Ast,
    //         tokens: TokenBundle,
    //     };
    //     pub const Bound = struct {
    //         semantic: Semantic,
    //     };
    // };

    pub const Index = enum(u32) {
        global,
        first,
        _,
        pub inline fn repr(self: Index) u32 {
            return @intFromEnum(self);
        }
    };

    pub fn bind(self: *Constellation, source: Source) BoundSource.Index {
        const index = self.next_id.fetchAdd(1, .SeqCst);
        try self.units.append(BoundSource{
            .source = source,
            .semantic = undefined,
            .arena = ArenaAllocator.init(self.allocator),
        });
        std.debug.assert(self.units.items.len == index.repr());
        var bound = &self.units.items[index];
        var builder = SemanticBuilder.init(self.allocator, &bound.arena);
        builder.withSource(&source);
        builder.build(source.text());
    }
};

const std = @import("std");
const dora = @import("dora");
const atomic = std.atomic;

const Semantic = @import("Semantic.zig");
const SemanticBuilder = @import("SemanticBuilder.zig");
const Source = @import("../source.zig").Source;
const TokenBundle = @import("./tokenizer.zig").TokenBundle;
const Ast = @import("./ast.zig").Ast;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const RwLock = std.Thread.RwLock;
const Mutex = std.Thread.Mutex;

const assert = std.debug.assert;
