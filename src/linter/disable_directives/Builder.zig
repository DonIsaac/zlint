const Builder = @This();

parser: Parser,
tokens: TokenList.Slice,
comments: *const Semantic.CommentList.Slice,
state: State,

pub const Error = error {
    IllegalGlobalDirective,
} || Allocator.Error;

const State = struct {
    /// global disable directives may be placed anywhere before the first
    /// non-doc comment token. Doc comments may have global disable directives.
    start_of_first_non_doc_tok: u32,
    pos: u32,
    did_check_for_globals: bool,

    const initial: State = .{
        .start_of_first_non_doc_tok = 0,
        .pos = 0,
        .did_check_for_globals = false,
    };
    fn transition(self: *State, next_start: usize) void {
        std.debug.assert(!self.did_check_for_globals);
        self.* = .{
            .pos = 0,
            .start_of_first_non_doc_tok = @intCast(next_start),
            .did_check_for_globals = true,
        };
    }
};

pub fn init(sema: *const Semantic) Builder {
    return .{
        .state = .initial,
        .parser = Parser.new(sema.source()),
        .tokens = sema.tokens().*,
        .comments = sema.comments(),
    };
}

pub fn next(
    self: *Builder,
    allocator: Allocator,
) Allocator.Error!?Comment {
    if (!self.state.did_check_for_globals) {
        const comment = try self.nextFromTokens(allocator);
        // A `null` without a transition means the token list ran out before a
        // non-doc token was found; there's nothing left to scan.
        if (comment != null or !self.state.did_check_for_globals) return comment;
    }
    return try self.nextFromComment(allocator);
}

fn nextFromTokens(
    self: *Builder,
    allocator: Allocator,
) Allocator.Error!?Comment {
    std.debug.assert(!self.state.did_check_for_globals);
    if (self.tokens.len <= self.state.pos) return null;

    const tags: []const Token.Tag = self.tokens.items(.tag);
    const locs: []const Token.Loc = self.tokens.items(.loc);

    const start = self.state.pos;

    for (start..self.tokens.len) |i| {
        switch (tags[i]) {
            .doc_comment, .container_doc_comment => {
                if (try self.parser.parse(allocator, .from(locs[i]))) |comment| {
                    self.state.pos = @intCast(i + 1);
                    return comment;
                }
            },
            else => {
                self.state.transition(locs[i].start);
                return null;
            },
        }
    }

    self.state.pos = @intCast(self.tokens.len);
    return null;
}

/// Look for global disable directives in normal comments by parsing
/// comments up to the first non-comment token.
fn nextFromComment(
    self: *Builder,
    allocator: Allocator,
) Allocator.Error!?Comment {
    const start = self.state.pos;
    for (start..self.comments.len) |i| {
        const comment = self.comments.get(i);
        if (comment.start >= self.state.start_of_first_non_doc_tok) break;
        const dd = try self.parser.parse(allocator, comment) orelse continue;
        self.state.pos = @intCast(i + 1);
        return dd;
    }
    return null;
}

const std = @import("std");
const Parser = @import("Parser.zig");
const Comment = @import("Comment.zig");
const Allocator = std.mem.Allocator;

const Semantic = @import("../../Semantic.zig");
const TokenList = Semantic.TokenList;
const Token = Semantic.Token;
