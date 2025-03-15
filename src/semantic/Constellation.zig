units: std.ArrayListUnmanaged(BoundSource),
next_id: atomic.Value(BoundSource.Index) = .init(.first),

pub const BoundSource = struct {
    source: Source,
    semantic: Semantic,
    pub const Index = enum(u32) {
        global,
        first,
        _,
    };
};

const std = @import("std");
const atomic = std.atomic;

const Semantic = @import("Semantic.zig");
const Source = @import("../source.zig").Source;
const TokenBundle = @import("./tokenizer.zig").TokenBundle;
const Ast = @import("./ast.zig").Ast;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const RwLock = std.Thread.RwLock;
