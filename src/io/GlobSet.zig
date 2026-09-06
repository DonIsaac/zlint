//! One or more globs. Matches a path if at least one pattern in the set matches it.
//!
//! Patterns follow `.gitignore` conventions, since `zlint.json`'s `ignore` and
//! the lines read out of a `.gitignore` share this type:
//!
//! - a pattern with no separator matches a basename at any depth, so `build`
//!   skips both `build/` and `src/build/`
//! - a pattern containing a separator is anchored to the walk root
//! - a trailing separator restricts a pattern to directories
//!
//! Directory paths carry a trailing separator (see `Walker.Entry.path`), and a
//! matched directory is never descended into, so `build` needs no `/**` suffix
//! to drop the subtree beneath it.
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
        if (matchOne(pattern, path)) {
            return true;
        }
    }
    return false;
}

fn matchOne(pattern: glob.Pattern, path: []const u8) bool {
    const dirs_only = endsWithSep(pattern);
    const pat = if (dirs_only) trimSep(pattern) else pattern;
    if (pat.len == 0) return false;

    const is_dir = endsWithSep(path);
    if (dirs_only and !is_dir) return false;
    const bare = if (is_dir) trimSep(path) else path;

    if (mem.indexOfAny(u8, pat, &separators) == null) {
        return glob.match(pat, basename(bare));
    }

    // `dir/**` is written expecting to match `dir/`, so try the path as given
    // before falling back to the form without the trailing separator.
    return glob.match(pat, path) or (is_dir and glob.match(pat, bare));
}

const separators = [_]u8{ '/', '\\' };

fn endsWithSep(str: []const u8) bool {
    return str.len > 0 and mem.indexOfScalar(u8, &separators, str[str.len - 1]) != null;
}

fn trimSep(str: []const u8) []const u8 {
    return mem.trimEnd(u8, str, &separators);
}

fn basename(path: []const u8) []const u8 {
    const sep = mem.lastIndexOfAny(u8, path, &separators) orelse return path;
    return path[sep + 1 ..];
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
const mem = std.mem;
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

test "a pattern with no separator matches a basename at any depth" {
    const set: GlobSet = .new(&[_]glob.Pattern{"build"});

    try t.expect(set.matches("build/"));
    try t.expect(set.matches("src/build/"));
    try t.expect(set.matches("a/b/c/build/"));
    // gitignore matches files, not just directories
    try t.expect(set.matches("src/build"));

    // a shared prefix is not a match
    try t.expect(!set.matches("buildkite/"));
    try t.expect(!set.matches("src/prebuild/"));
    try t.expect(!set.matches("build.zig"));
}

test "a pattern with a separator is anchored to the walk root" {
    const set: GlobSet = .new(&[_]glob.Pattern{"src/build"});

    try t.expect(set.matches("src/build/"));
    try t.expect(!set.matches("lib/src/build/"));
    try t.expect(!set.matches("build/"));

    const anywhere: GlobSet = .new(&[_]glob.Pattern{"**/generated"});
    try t.expect(anywhere.matches("src/generated/"));
    try t.expect(anywhere.matches("lib/generated/"));
    try t.expect(anywhere.matches("generated/"));
}

test "a trailing separator restricts a pattern to directories" {
    const set: GlobSet = .new(&[_]glob.Pattern{"build/"});

    try t.expect(set.matches("build/"));
    try t.expect(set.matches("src/build/"));
    // `build` the file is left alone
    try t.expect(!set.matches("build"));
    try t.expect(!set.matches("src/build"));
}

test "wildcards match basenames when unanchored" {
    const set: GlobSet = .new(&[_]glob.Pattern{"*.gen.zig"});

    try t.expect(set.matches("proto.gen.zig"));
    try t.expect(set.matches("src/deep/proto.gen.zig"));
    try t.expect(!set.matches("src/proto.zig"));
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
