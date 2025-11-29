const Parse = @This();

ast: Ast,
// NOTE: We re-tokenize and store our own tokens b/c AST throws away the end
// position of each token. B/c of this, `ast.stokenSlice` re-tokenizes each
// time. So we do it once, eat the memory overhead, and help the linter avoid
// constant re-tokenization.
// NOTE: allocated in _arena
tokens: TokenList.Slice,
comments: CommentList.Slice,

pub fn build(
    allocator: Allocator,
    source: [:0]const u8,
) Allocator.Error!struct { Parse, tokenizer.TokenBundle.Stats } {
    var token_bundle = try tokenizer.tokenize(
        allocator,
        source,
    );
    errdefer {
        // NOTE: free'd in reverse order they're allocated
        token_bundle.comments.deinit(allocator);
        token_bundle.tokens.deinit(allocator);
    }

    const ast = try Ast.parse(allocator, source, .zig);
    return .{
        Parse{
            .ast = ast,
            .tokens = token_bundle.tokens,
            .comments = token_bundle.comments,
        },
        token_bundle.stats,
    };
}

pub fn deinit(self: *Parse, allocator: Allocator) void {
    self.ast.deinit(allocator);
    self.tokens.deinit(allocator);
    self.comments.deinit(allocator);
}

const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const zig = @import("../zig.zig").@"0.14.1";
const Allocator = std.mem.Allocator;
const Ast = zig.Ast;
const TokenList = tokenizer.TokenList;
const CommentList = tokenizer.CommentList;
