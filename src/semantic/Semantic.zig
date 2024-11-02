//! semantic analysis of a zig AST.
//!
//! We are intentionally not using Zig's AIR. That format strips away dead
//! code, which may be in the process of being authored. Instead, we perform
//! our own minimalist semantic analysis of an entire zig program.
//!
//! Additionally, we're avoiding an SoA (struct of arrays) format for now. Zig
//! (and many other parsers/analysis tools) use this to great perf advantage.
//! However, it sucks to work with when writing rules. We opt for simplicity to
//! reduce cognitive load and make contributing rules easier.
//!
//! Throughout this file you'll see mentions of a "program". This does not mean
//! an entire linked binary or library; rather it refers to a single parsed
//! file.

symbols: SymbolTable = .{},
scopes: ScopeTree = .{},
ast: Ast, // NOTE: allocated in _arena
_gpa: Allocator,
/// Used to allocate AST nodes
_arena: ArenaAllocator,

pub const ROOT_SCOPE_ID: Scope.Id = 0;

pub fn deinit(self: *Semantic) void {
    // NOTE: ast is arena allocated, so no need to deinit it. freeing the arena
    // is sufficient.
    self._arena.deinit();
    self.symbols.deinit(self._gpa);
    self.scopes.deinit(self._gpa);
    // SAFETY: *self is no longer valid after deinitilization.
    self.* = undefined;
}

const Semantic = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Ast = std.zig.Ast;
const Type = std.builtin.Type;
const assert = std.debug.assert;

const scope = @import("./scope.zig");
const symbol = @import("./symbol.zig");
pub const Scope = scope.Scope;
pub const Symbol = symbol.Symbol;
pub const ScopeTree = scope.ScopeTree;
pub const SymbolTable = symbol.SymbolTable;

const str = @import("../str.zig");
const string = str.string;
const stringSlice = str.stringSlice;
