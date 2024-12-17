const std = @import("std");
const util = @import("util");
const _ast = @import("./ast.zig");
const span = @import("../span.zig");

const Token = _ast.Token;
const TokenList = _ast.TokenList;
const Allocator = std.mem.Allocator;
const Span = span.Span;

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
    comments: *std.ArrayListUnmanaged(Span),
) !TokenList {
    util.debugAssert(comments.items.len == 0, "non-empty comment buffer passed to tokenize", .{});
    var tokens = std.MultiArrayList(Token){};
    errdefer tokens.deinit(allocator);

    // Empirically, the zig std lib has an 8:1 ratio of source bytes to token count.
    const estimated_token_count = source.len / 8;
    try tokens.ensureTotalCapacity(allocator, estimated_token_count);

    var tokenizer = std.zig.Tokenizer.init(source);

    var prev_end: u32 = 0;
    while (true) {
        @setRuntimeSafety(true);
        const token = tokenizer.next();
        try scanForComments(allocator, source[prev_end..token.loc.start], prev_end, comments);
        try tokens.append(allocator, token);
        util.assert(token.loc.end < std.math.maxInt(u32), "token exceeds u32 limit", .{});
        prev_end = @truncate(token.loc.end);
        if (token.tag == .eof) break;
    }
    return tokens.slice();
}

/// Scan the gap between two tokens for a comment.
/// There will only ever be 0 or 1 comment between two tokens.
fn scanForComments(
    allocator: Allocator,
    // source slice between two tokens
    source_between: []const u8,
    offset: u32,
    comments: *std.ArrayListUnmanaged(Span),
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
    var comments: std.ArrayListUnmanaged(Span) = .{};
    defer comments.deinit(t.allocator);

    const simple = "// foo";
    try scanForComments(t.allocator, simple, 0, &comments);
    try t.expectEqual(1, comments.items.len);
    try t.expectEqual(comments.items[0], Span{ .start = 0, .end = 6 });

    const multi_slash = "//////////foo//";
    try scanForComments(t.allocator, multi_slash, 0, &comments);
    try t.expectEqual(1, comments.items.len);
    try t.expectEqual(comments.items[0], Span{ .start = 0, .end = multi_slash.len });

}
