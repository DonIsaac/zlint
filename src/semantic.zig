//! semantic analysis of a zig AST.
//!
//! We are intentionally not using Zig's AIR. That format strips away dead
//! code, which may be in the process of being authored. Instead, we perform
//! our own minimalist semantic analysis of an entire zig program.
//!
//! Throughout this file you'll see mentions of a "program". This does not mean
//! an entire linked binary or library; rather it refers to a single parsed
//! file.

pub const SemanticBuilder = @import("./semantic/SemanticBuilder.zig");

pub const Semantic = @import("./semantic/Semantic.zig");
// parts of semantic
pub const Ast = std.zig.Ast;
pub const Symbol = @import("./semantic/Symbol.zig");
pub const SymbolTable = Symbol.SymbolTable;
pub const Scope = @import("./semantic/Scope.zig");
pub const ScopeTree = Scope.ScopeTree;

const std = @import("std");
