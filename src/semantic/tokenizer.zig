const std = @import("std");
const util = @import("util");
const span = @import("../span.zig");

const Allocator = std.mem.Allocator;
const Span = span.Span;

pub const Token = std.zig.Token;
pub const TokenList = std.MultiArrayList(Token);
pub const CommentList = std.MultiArrayList(Span);

pub const TokenBundle = struct {
    tokens: TokenList.Slice,
    /// Doc and "normal" comments found in the tokenized source.
    ///
    /// Comments are always sorted by their position within the source. That is,
    /// ```
    /// \forall i \st i < comments.len-1 | comments[i] < comments[i+1]
    /// ```
    comments: CommentList.Slice,
    stats: Stats,

    const Stats = struct {
        /// Number of identifier tokens encountered.
        identifiers: u32 = 0,
    };
};

/// Tokenize Zig source code.
///
/// Copied + modified from `Ast.parse`. We tokenize and keep our own copy of the
/// token list because Ast discards token end positions. Lacking this,
/// `ast.tokenSlice` requires re-tokenization on each call for (e.g.) identifier
/// tokens.
///
/// Zig's tokenizer also discards comments completely. We need this for (e.g.)
/// disable directives, so we need to store them ourselves.
pub fn tokenize(
    // Should be an arena
    allocator: Allocator,
    source: [:0]const u8,
) Allocator.Error!TokenBundle {
    var tokens = TokenList{};
    var comments = CommentList{};
    var stats: TokenBundle.Stats = .{};
    errdefer {
        tokens.deinit(allocator);
        comments.deinit(allocator);
    }

    // Empirically, the zig std lib has an 8:1 ratio of source bytes to token count.
    const estimated_token_count = source.len / 8;
    try tokens.ensureTotalCapacity(allocator, estimated_token_count);
    // TODO: collect data and find the best starting capacity
    try comments.ensureTotalCapacity(allocator, 16);

    var tokenizer = std.zig.Tokenizer.init(source);

    var prev_end: u32 = 0;
    while (true) {
        @setRuntimeSafety(true);
        const token = tokenizer.next();
        try scanForComments(allocator, source[prev_end..token.loc.start], prev_end, &comments);
        try tokens.append(allocator, token);
        util.assert(token.loc.end < std.math.maxInt(u32), "token exceeds u32 limit", .{});
        prev_end = @truncate(token.loc.end);
        switch (token.tag) {
            .identifier => stats.identifiers += 1,
            .eof => break,
            else => {},
        }
    }

    return .{
        .tokens = tokens.slice(),
        .comments = comments.slice(),
        .stats = stats,
    };
}

/// Scan the gap between two tokens for a comment.
/// There will only ever be 0 or 1 comment between two tokens.
fn scanForComments(
    allocator: Allocator,
    // source slice between two tokens
    source_between: []const u8,
    offset: u32,
    comments: *CommentList,
) Allocator.Error!void {
    var cursor: u32 = 0;
    // consecutive slashes seen
    var slashes_seen: u8 = 0;
    var in_comment_line = false;
    var start: ?u32 = null;
    while (cursor < source_between.len) : (cursor += 1) {
        const c = source_between[cursor];
        switch (c) {
            ' ' | '\t' => continue,
            '/' => {
                // careful not to overflow if, e.g. `///////////////////` (etc.)
                if (!in_comment_line) slashes_seen += 1;
                if (!in_comment_line and slashes_seen >= 2) {
                    in_comment_line = true;
                    // may have more than one line comment in a row
                    if (start == null) start = (cursor + 1) - slashes_seen;
                }
            },
            '\n' => {
                if (in_comment_line) {
                    try comments.append(allocator, Span.new(start.? + offset, cursor + offset));
                    in_comment_line = false;
                    start = null;
                    slashes_seen = 0;
                    // may have more than one line comment in a row, so keep
                    // walking
                }
            },
            else => continue,
        }
    }
    // Happens when EOF is reached before a newline
    if (in_comment_line and start != null) {
        try comments.append(allocator, Span.new(start.? + offset, cursor + offset));
    }
}

const t = std.testing;
test scanForComments {
    var comments: CommentList = .{};
    defer comments.deinit(t.allocator);

    {
        defer comments.len = 0;
        const simple = "// foo";
        try scanForComments(t.allocator, simple, 0, &comments);
        try t.expectEqual(1, comments.len);
        try t.expectEqual(comments.get(0), Span{ .start = 0, .end = simple.len });
    }

    // doc comments
    {
        defer comments.len = 0;
        const source = "/// foo";
        try scanForComments(t.allocator, source, 0, &comments);
        try t.expectEqual(1, comments.len);
        try t.expectEqual(comments.get(0), Span{ .start = 0, .end = source.len });
    }
    {
        defer comments.len = 0;
        const source = "//! foo";
        try scanForComments(t.allocator, source, 0, &comments);
        try t.expectEqual(1, comments.len);
        try t.expectEqual(comments.get(0), Span{ .start = 0, .end = source.len });
    }

    // weird comments
    {
        defer comments.len = 0;
        const multi_slash = "//////////foo//";
        try scanForComments(t.allocator, multi_slash, 0, &comments);
        try t.expectEqual(1, comments.len);
        try t.expectEqual(comments.get(0), Span{ .start = 0, .end = multi_slash.len });
    }

    // multiple comments
    {
        defer comments.len = 0;
        const source =
            \\// foo
            \\// bar
        ;
        try scanForComments(t.allocator, source, 0, &comments);
        try t.expectEqual(2, comments.len);
        try t.expectEqual(comments.get(0), Span{ .start = 0, .end = 6 });
        try t.expectEqual(comments.get(1), Span{ .start = 7, .end = source.len });
        try t.expectEqual(source[6], '\n');
        try t.expectEqual(source[7], '/');
    }
}

test "Comments are always sorted by their position within source code" {
    const src =
        \\//! foo
        \\//! bar
        \\pub fn foo() u32 { // a thing
        \\  const x = 1;
        \\  // another thing
        \\  return x;
        \\}
        \\
        \\// a comment
        \\const x = 1;
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const bundle = try tokenize(arena.allocator(), src);

    var prev = bundle.comments.get(0);
    try t.expect(prev.start <= prev.end);

    for (1..bundle.comments.len) |i| {
        const curr = bundle.comments.get(i);
        try t.expect(prev.end < curr.start);
        prev = curr;
    }
}
