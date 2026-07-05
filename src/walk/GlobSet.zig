//! One or more globs. Matches a path if at least one pattern in the set matches it.
const GlobSet = @This();

patterns: []const glob.Pattern,

/// A GlobSet that matches nothing
pub const empty: GlobSet = .{ .patterns = &[_]glob.Pattern{} };

pub inline fn new(patterns: []const []const u8) GlobSet {
    return .{ .patterns = patterns };
}

/// Returns `true` if any pattern in this set matches `path`.
pub fn matches(self: GlobSet, path: []const u8) bool {
    for (self.patterns) |pattern| {
        if (glob.match(pattern, path)) {
            return true;
        }
    }
    return false;
}

pub fn jsonParse(allocator: Allocator, source: *json.Scanner, options: json.ParseOptions) ParseError!GlobSet {
    return .new(try json.parseFromTokenSourceLeaky(
        @FieldType(GlobSet, "patterns"),
        allocator,
        source,
        options,
    ));
}

pub fn jsonSchema(ctx: *Schema.Context) !Schema {
    return ctx.genSchemaInner(@FieldType(GlobSet, "patterns"));
}

const std = @import("std");
const Schema = @import("../json.zig").Schema;
const glob = @import("./glob.zig");
const json = std.json;
const Allocator = std.mem.Allocator;
const ParseError = json.ParseError(json.Scanner);

// =============================================================================

const t = std.testing;
test matches {
    const ignoreDefault: GlobSet = .new(&[_]glob.Pattern{ "vendor/**", "zig-out/**", "zig-pkg/**" });
    try t.expect(ignoreDefault.matches("vendor/foo.zig"));
    try t.expect(ignoreDefault.matches("zig-out/foo/bar.zig"));
    try t.expect(ignoreDefault.matches("zig-out/bin"));
    try t.expect(ignoreDefault.matches("zig-out/bin/"));
    try t.expect(ignoreDefault.matches("zig-pkg/zlint"));
    try t.expect(!ignoreDefault.matches("src/foo/bar.zig"));

    try t.expect(!GlobSet.empty.matches("vendor/foo.zig"));
    try t.expect(!GlobSet.empty.matches("zig-out/foo/bar.zig"));
    try t.expect(!GlobSet.empty.matches(""));
}

test "directory paths include trailing separator" {
    const ignoreDefault: GlobSet = .new(&[_]glob.Pattern{ "vendor/**", "zig-out/**", "zig-pkg/**" });

    try t.expect(!ignoreDefault.matches("zig-pkg"));
    try t.expect(ignoreDefault.matches("zig-pkg/"));
    try t.expect(ignoreDefault.matches("vendor/"));
    try t.expect(ignoreDefault.matches("zig-out/"));

    try t.expect(!ignoreDefault.matches("src/vendor/"));

    const nested: GlobSet = .new(&[_]glob.Pattern{"**/vendor/**"});
    try t.expect(nested.matches("vendor/"));
    try t.expect(nested.matches("src/vendor/"));
    try t.expect(!nested.matches("src/"));
}

test jsonParse {
    var value = try json.parseFromSlice(
        GlobSet,
        t.allocator,
        \\["foo/**"]
    ,
        .{},
    );
    defer value.deinit();
    const ignore = value.value;
    try t.expectEqual(ignore.patterns.len, 1);
    try t.expectEqualStrings(ignore.patterns[0], "foo/**");
}
