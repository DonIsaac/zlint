//! One or more globs. Positive patterns include paths; later negated patterns
//! can re-include them.
//!
//! Patterns are plain globs, anchored to the walk root: `build` names one entry
//! there, `**/build` names it at any depth, and `**/build/**` names what is
//! inside it. A leading `!` negates a pattern, re-including what earlier ones
//! matched. `.gitignore` lines mean something different by the same string, so
//! they are translated into these globs when read (see `gitignoreLineToGlobs`).
//!
//! Directory paths carry a trailing separator (see `Walker.Entry.path`), which
//! a pattern naming that directory does not, so both forms are tried.
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
    return if (self.has_negated)
        self.matchesWithNegation(path)
    else
        self.matchesSimple(path);
}

fn matchesSimple(self: GlobSet, path: []const u8) bool {
    for (self.patterns) |pattern| {
        if (matchOne(pattern, path)) {
            return true;
        }
    }
    return false;
}

fn matchesWithNegation(self: GlobSet, path: []const u8) bool {
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
pub fn matchesPrunableDirectory(self: GlobSet, path: []const u8) bool {
    if (!self.matches(path)) return false;
    if (!self.has_negated) return true;

    for (self.patterns) |pattern| {
        const body = negatedPattern(pattern) orelse continue;
        if (negationCouldMatchBeneath(body, path)) return false;
    }
    return true;
}

/// Conservatively reports whether a negated pattern's body could match any path
/// below `dir`. Only `false` is load-bearing: it permits a prune.
fn negationCouldMatchBeneath(pattern: glob.Pattern, dir: []const u8) bool {
    var pattern_components = mem.tokenizeAny(u8, trimSep(pattern), &separators);
    var dir_components = mem.tokenizeAny(u8, dir, &separators);
    while (dir_components.next()) |dir_component| {
        const pattern_component = pattern_components.next() orelse return false;
        if (mem.eql(u8, pattern_component, "**")) return true;
        if (!glob.match(pattern_component, dir_component)) return false;
    }

    // anything left over is what the pattern would match beneath `dir`
    return pattern_components.next() != null;
}

fn hasNegatedPatterns(patterns: []const glob.Pattern) bool {
    for (patterns) |pattern| {
        if (negatedPattern(pattern) != null) return true;
    }
    return false;
}

fn negatedPattern(pattern: glob.Pattern) ?glob.Pattern {
    return if (pattern.len > 0 and pattern[0] == '!') pattern[1..] else null;
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
    if (pattern.len == 0) return false;

    // Directory paths carry a trailing separator, which a pattern naming that
    // directory does not, so try both forms.
    const is_dir = endsWithSep(path);
    return glob.match(pattern, path) or
        (is_dir and glob.match(pattern, trimSep(path)));
}

const separators = [_]u8{ '/', '\\' };

fn endsWithSep(str: []const u8) bool {
    return str.len > 0 and mem.indexOfScalar(u8, &separators, str[str.len - 1]) != null;
}

fn trimSep(str: []const u8) []const u8 {
    return mem.trimEnd(u8, str, &separators);
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

test "a pattern without a `**/` prefix is anchored to the walk root" {
    const set: GlobSet = .new(&[_]glob.Pattern{"build"});

    try t.expect(set.matches("build/"));
    // matches files, not just directories
    try t.expect(set.matches("build"));

    try t.expect(!set.matches("src/build/"));
    try t.expect(!set.matches("a/b/c/build/"));

    // a shared prefix is not a match
    try t.expect(!set.matches("buildkite/"));
    try t.expect(!set.matches("build.zig"));
}

test "a `**/` prefix matches at any depth" {
    const set: GlobSet = .new(&[_]glob.Pattern{"**/build"});

    try t.expect(set.matches("build/"));
    try t.expect(set.matches("src/build/"));
    try t.expect(set.matches("a/b/c/build/"));

    try t.expect(!set.matches("src/prebuild/"));
    // naming a folder says nothing about what is inside it
    try t.expect(!set.matches("src/build/main.zig"));
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

test "a `/**` suffix matches what is inside a folder" {
    const set: GlobSet = .new(&[_]glob.Pattern{"**/build/**"});

    try t.expect(set.matches("build/main.zig"));
    try t.expect(set.matches("src/build/deep/main.zig"));
    // also matches the folder itself, which is what lets the walker prune it
    try t.expect(set.matches("build/"));
    try t.expect(!set.matches("build"));
}

test "a wildcard does not cross separators" {
    const set: GlobSet = .new(&[_]glob.Pattern{"*.gen.zig"});

    try t.expect(set.matches("proto.gen.zig"));
    try t.expect(!set.matches("src/deep/proto.gen.zig"));
    try t.expect(!set.matches("src/proto.zig"));

    const any_depth: GlobSet = .new(&[_]glob.Pattern{"**/*.gen.zig"});
    try t.expect(any_depth.matches("proto.gen.zig"));
    try t.expect(any_depth.matches("src/deep/proto.gen.zig"));
    try t.expect(!any_depth.matches("src/proto.zig"));
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

test "a negation elsewhere in the set does not block pruning" {
    const set: GlobSet = .new(&[_]glob.Pattern{ "**/build", "**/build/**", "!src/keep.zig" });

    try t.expect(set.matchesPrunableDirectory("build/"));
    try t.expect(set.matchesPrunableDirectory("src/build/"));
    try t.expect(!set.matchesPrunableDirectory("src/"));
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
