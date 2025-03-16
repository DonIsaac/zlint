const Constellation = @This();

allocator: Allocator,
unit_lock: std.Thread.Mutex = .{},
units: dora.AutoDora(BoundSource.Index, BoundSource),
next_id: atomic.Value(BoundSource.Index) = .init(.first),

pub fn addUninitialized(self: *Constellation, source: Source) BoundSource.Index {
    const index = self.next_id.fetchAdd(1, .SeqCst);
    {
        self.unit_lock.lock();
        defer self.unit_lock.unlock();
        try self.units.append(BoundSource{
            .source = source,
            .semantic = undefined,
            .arena = ArenaAllocator.init(self.allocator),
        });
        assert(self.units.items.len == @as(u32, @bitCast(index)));
    }
    return index;
}
pub const GlobalSymbolId = struct {
    source: BoundSource.Index,
    symbol: Semantic.Symbol.Id,
};

pub const BoundSource = struct {
    /// Bound source where this symbol is defined.
    source: Source,
    semantic: Semantic,
    arena: ArenaAllocator,
    lock: RwLock = .{},

    pub const Index = enum(u32) {
        global,
        first,
        _,
    };

    pub fn bind(self: *Constellation, source: Source) BoundSource.Index {
        const index = self.next_id.fetchAdd(1, .SeqCst);
        try self.units.append(BoundSource{
            .source = source,
            .semantic = undefined,
            .arena = ArenaAllocator.init(self.allocator),
        });
        std.debug.assert(self.units.items.len == @as(u32, @bitCast(index)));
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
