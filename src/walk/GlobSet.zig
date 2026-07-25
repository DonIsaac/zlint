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
    // NOTE: must be `innerParse`, not a whole-document entry point like
    // `parseFromTokenSourceLeaky`. Those assert that the scanner is at
    // `.end_of_document` when they return, which is never true when a GlobSet is
    // a field of an enclosing object (e.g. `Config.ignore`).
    return .new(try json.innerParse(
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

// Regression test for https://github.com/DonIsaac/zlint/issues/358: parsing a
// GlobSet nested within an enclosing object crashed, since the scanner is not at
// the end of the document once the set's patterns have been consumed.
test "jsonParse within an enclosing object" {
    const Wrapper = struct { ignore: GlobSet = .empty, after: u32 = 0 };
    var value = try json.parseFromSlice(
        Wrapper,
        t.allocator,
        \\{ "ignore": ["foo/**", "bar/*.zig"], "after": 1 }
    ,
        .{},
    );
    defer value.deinit();
    const wrapper = value.value;
    try t.expectEqual(2, wrapper.ignore.patterns.len);
    try t.expectEqualStrings("foo/**", wrapper.ignore.patterns[0]);
    try t.expectEqualStrings("bar/*.zig", wrapper.ignore.patterns[1]);
    // fields following the glob set still parse
    try t.expectEqual(1, wrapper.after);
}
