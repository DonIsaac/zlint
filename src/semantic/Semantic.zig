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

/// The scope created by a program/compilation unit.
///
/// The root scope is eventually the parent of all other scopes. Its parent is
/// always `null`.
pub const ROOT_SCOPE_ID: Scope.Id = 0;
/// The root node always has an index of 0. Since it is never referenced by other nodes,
/// the Zig team uses it to represent `null` without wasting extra memory.
pub const ROOT_NODE_ID: Ast.Node.Index = 0;
/// Alias for `ROOT_NODE_ID`. Used in null-node check contexts for code clarity.
pub const NULL_NODE: Ast.Node.Index = ROOT_NODE_ID;

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
pub const Symbol = @import("./Symbol.zig");
pub const SymbolTable = Symbol.SymbolTable;
pub const Scope = scope.Scope;
pub const ScopeTree = scope.ScopeTree;

const util = @import("util");
const string = util.string;
const stringSlice = util.stringSlice;
