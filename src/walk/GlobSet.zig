//! One or more globs. Positive patterns include paths; later negated patterns
//! can re-include them.
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
        } else if (glob.match(pattern, path)) {
            matched = true;
        }
    }
    return matched;
}

fn hasNegatedPatterns(patterns: []const glob.Pattern) bool {
    for (patterns) |pattern| {
        if (negatedPattern(pattern) != null) return true;
    }
    return false;
}

/// Returns `true` if a directory can be pruned without hiding a later
/// re-included descendant.
pub inline fn matchesPrunableDirectory(self: GlobSet, path: []const u8) bool {
    return !self.has_negated and self.matches(path);
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
    return glob.match(pattern[pattern_index..], path[path_index..]);
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
