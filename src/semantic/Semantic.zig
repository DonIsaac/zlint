//! semantic analysis of a Zig AST.
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
// NOTE: We re-tokenize and store our own tokens b/c AST throws away the end
// position of each token. B/c of this, `ast.stokenSlice` re-tokenizes each
// time. So we do it once, eat the memory overhead, and help the linter avoid
// constant re-tokenization.
// NOTE: allocated in _arena
tokens: TokenList,
node_links: NodeLinks,
_gpa: Allocator,
/// Used to allocate AST nodes
_arena: ArenaAllocator,

/// The scope where symbols built in to the language are declared.
///
/// The root scope is eventually the parent of all other scopes. Its parent is
/// always `null`.
pub const BUILTIN_SCOPE_ID: Scope.Id = Scope.Id.from(1);
/// The scope created by a program/compilation unit.
///
/// Its parent is always `BUILTIN_SCOPE_ID`.
///
/// > _note_: right now root/builtin scope ids are the same. This may change in
/// the future.
pub const ROOT_SCOPE_ID: Scope.Id = Scope.Id.from(0);
/// The root node always has an index of 0. Since it is never referenced by other nodes,
/// the Zig team uses it to represent `null` without wasting extra memory.
pub const ROOT_NODE_ID: Ast.Node.Index = 0;
/// Alias for `ROOT_NODE_ID`. Used in null-node check contexts for code clarity.
pub const NULL_NODE: Ast.Node.Index = ROOT_NODE_ID;

pub fn tokenSlice(self: *const Semantic, token: TokenIndex) []const u8 {
    const loc: Token.Loc = self.tokens.items(.loc)[token];
    return self.ast.source[loc.start..loc.end];
}

/// Find the symbol bound to an identifier name that was declared in some scope.
///
/// To find a binding that is referrable within a scope, but that may not have
/// been declared in it, use `resolveBinding`.
pub fn getBinding(self: *const Semantic, scope_id: Scope.Id, name: []const u8) ?Symbol.Id {
    const bindings = self.scopes.getBindings(scope_id);
    const names = self.symbols.symbols.items(.name);
    for (bindings) |symbol_id| {
        if (std.mem.eql(u8, names[symbol_id.into(usize)], name)) {
            return symbol_id;
        }
    }
    return null;
}

/// Find an in-scope symbol bound to an identifier name.
///
/// To only find symbols declared within a scope, use `getBinding`.
pub fn resolveBinding(self: *const Semantic, scope_id: Scope.Id, name: []const u8) ?Symbol.Id {
    var it = self.scopes.iterParents(scope_id);
    while (it.next()) |scope| {
        if (self.getBinding(scope, name)) |binding| return binding;
    }
    return null;
}

pub fn deinit(self: *Semantic) void {
    // NOTE: ast and tokens are arena allocated, so no need to deinit it.
    // freeing the arena is sufficient.
    self._arena.deinit();
    self.node_links.deinit(self._gpa);
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
const Token = std.zig.Token;
const Type = std.builtin.Type;
const assert = std.debug.assert;

const _ast = @import("./ast.zig");
const TokenList = _ast.TokenList;
const TokenIndex = _ast.TokenIndex;

pub const NodeLinks = @import("NodeLinks.zig");
pub const Scope = @import("Scope.zig");
pub const ScopeTree = Scope.ScopeTree;
pub const Symbol = @import("Symbol.zig");
pub const SymbolTable = Symbol.SymbolTable;
pub const Reference = @import("Reference.zig");

const util = @import("util");
const string = util.string;
const stringSlice = util.stringSlice;
