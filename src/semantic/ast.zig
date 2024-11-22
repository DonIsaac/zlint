//! Re-exports of data structures used in Zig's AST.
//!
//! Also includes additional types used in other semantic components.
const std = @import("std");
const NominalId = @import("id.zig").NominalId;

pub const Ast = std.zig.Ast;
pub const Node = Ast.Node;
pub const Token = std.zig.Token;

/// The struct used in AST tokens SOA is not pub so we hack it in here.
pub const RawToken = struct {
    tag: std.zig.Token.Tag,
    start: Ast.ByteOffset,
    pub const Tag = std.zig.Token.Tag;
};

pub const TokenIndex = Ast.TokenIndex;
pub const NodeIndex = Node.Index;
pub const MaybeTokenId = NominalId(Ast.TokenIndex).Optional;
