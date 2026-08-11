//! Re-exports of data structures used in Zig's AST.
//!
//! Also includes additional types used in other semantic components.
const std = @import("std");
const NominalId = @import("util").NominalId;
const zig = std.zig;

pub const Ast = zig.Ast;
pub const Node = Ast.Node;

pub const TokenIndex = Ast.TokenIndex;
pub const NodeIndex = Node.Index;
pub const MaybeTokenId = NominalId(Ast.TokenIndex).Optional;
