//! One or more globs. Positive patterns include paths; later negated patterns
//! can re-include them.
//!
//! Patterns follow `.gitignore` conventions, since `zlint.json`'s `ignore` and
//! the lines read out of a `.gitignore` share this type:
//!
//! - a pattern with no separator matches a basename at any depth, so `build`
//!   skips both `build/` and `src/build/`
//! - a pattern containing a separator is anchored to the walk root
//! - a trailing separator restricts a pattern to directories
//! - a leading `!` negates a pattern, re-including what earlier ones matched
//!
//! Directory paths carry a trailing separator (see `Walker.Entry.path`), and a
//! matched directory is never descended into, so `build` needs no `/**` suffix
//! to drop the subtree beneath it.
const GlobSet = @This();

patterns: []const glob.Pattern,
has_negated: bool,

/// A GlobSet that matches nothing
pub const empty: GlobSet = .{
    .patterns = &[_]glob.Pattern{},
    .has_negated = false,
};

pub fn new(patterns: []const []const u8) GlobSet {
    return .{
        .patterns = patterns,
        .has_negated = hasNegatedPatterns(patterns),
    };
}

/// Returns `true` if the last matching pattern in this set is positive.
pub fn matches(self: GlobSet, path: []const u8) bool {
    var matched = false;
    for (self.patterns) |pattern| {
        if (negatedPattern(pattern)) |positive_pattern| {
            if (matchNegatedPatternBody(positive_pattern, path)) {
                matched = false;
            }
        } else if (matchOne(pattern, path)) {
            matched = true;
        }
    }
    return matched;
}

/// Returns `true` if a directory can be pruned without hiding a later
/// re-included descendant.
pub inline fn matchesPrunableDirectory(self: GlobSet, path: []const u8) bool {
    return !self.has_negated and self.matches(path);
}

fn hasNegatedPatterns(patterns: []const glob.Pattern) bool {
    for (patterns) |pattern| {
        if (negatedPattern(pattern) != null) return true;
    }
    return false;
}

fn negatedPattern(pattern: glob.Pattern) ?glob.Pattern {
    return if (pattern.len > 0 and pattern[0] == '!') return pattern[1..] else null;
}

fn matchNegatedPatternBody(pattern: glob.Pattern, path: []const u8) bool {
    var pattern_index: usize = 0;
    var path_index: usize = 0;
    while (pattern_index < pattern.len and pattern[pattern_index] == '!') : (pattern_index += 1) {
        if (path_index >= path.len or path[path_index] != '!') return false;
        path_index += 1;
    }
    return matchOne(pattern[pattern_index..], path[path_index..]);
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

test "negated patterns re-include later matches" {
    const set: GlobSet = .new(&[_]glob.Pattern{ "dist/**", "!dist/keep.zig" });

    try t.expect(set.matches("dist/bad.zig"));
    try t.expect(!set.matches("dist/keep.zig"));
}

test "pattern order controls negation results" {
    const set: GlobSet = .new(&[_]glob.Pattern{
        "dist/**",
        "!dist/keep/**",
        "dist/keep/generated.zig",
    });

    try t.expect(set.matches("dist/bad.zig"));
    try t.expect(!set.matches("dist/keep/manual.zig"));
    try t.expect(set.matches("dist/keep/generated.zig"));
}

test "negated pattern without prior positive match stays unmatched" {
    const set: GlobSet = .new(&[_]glob.Pattern{"!src/generated.zig"});

    try t.expect(!set.matches("src/generated.zig"));
    try t.expect(!set.matches("src/manual.zig"));
}

test "negated pattern body treats additional leading bang literally" {
    const set: GlobSet = .new(&[_]glob.Pattern{ "*.zig", "!!keep.zig" });

    try t.expect(!set.matches("!keep.zig"));
    try t.expect(set.matches("!other.zig"));
}

test "escaped leading bang remains literal" {
    const set: GlobSet = .new(&[_]glob.Pattern{"\\!literal.zig"});

    try t.expect(set.matches("!literal.zig"));
    try t.expect(!set.matches("literal.zig"));
}

test "new caches negated pattern detection" {
    try t.expect(GlobSet.new(&[_]glob.Pattern{ "dist/**", "!dist/keep.zig" }).has_negated);
    try t.expect(!GlobSet.new(&[_]glob.Pattern{ "dist/**", "\\!literal.zig", "[!a].zig" }).has_negated);
}

test matchesPrunableDirectory {
    try t.expect(GlobSet.new(&[_]glob.Pattern{"dist/**"}).matchesPrunableDirectory("dist/"));
    try t.expect(!GlobSet.new(&[_]glob.Pattern{ "dist/**", "!dist/keep.zig" }).matchesPrunableDirectory("dist/"));
    try t.expect(!GlobSet.new(&[_]glob.Pattern{ "dist/**", "!dist/keep.zig" }).matchesPrunableDirectory("src/"));
}

test jsonParse {
    var value = try json.parseFromSlice(
        GlobSet,
        t.allocator,
        \\["foo/**", "!foo/bar/*"]
    ,
        .{},
    );
    defer value.deinit();
    const ignore = value.value;
    try t.expectEqual(ignore.patterns.len, 2);
    try t.expectEqualStrings(ignore.patterns[0], "foo/**");
    try t.expectEqualStrings(ignore.patterns[1], "!foo/bar/*");
    try t.expect(ignore.has_negated);
}

test "jsonParse caches absence of negated patterns" {
    var value = try json.parseFromSlice(
        GlobSet,
        t.allocator,
        "[\"foo/**\"]",
        .{},
    );
    defer value.deinit();
    const ignore = value.value;
    try t.expect(!ignore.has_negated);
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
