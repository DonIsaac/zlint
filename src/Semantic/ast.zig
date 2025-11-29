//! Re-exports of data structures used in Zig's AST.
//!
//! Also includes additional types used in other semantic components.
const std = @import("std");
const NominalId = @import("util").NominalId;
const zig = @import("../zig.zig").@"0.14.1";

pub const Ast = zig.Ast;
pub const Node = Ast.Node;

/// The struct used in AST tokens SOA is not pub so we hack it in here.
pub const RawToken = struct {
    tag: zig.Token.Tag,
    start: Ast.ByteOffset,
    pub const Tag = zig.Token.Tag;
};

pub const TokenIndex = Ast.TokenIndex;
pub const NodeIndex = Node.Index;
pub const MaybeTokenId = NominalId(Ast.TokenIndex).Optional;
