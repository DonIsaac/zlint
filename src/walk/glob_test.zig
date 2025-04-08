const std = @import("std");
const expect = std.testing.expect;
const match = @import("glob.zig").match;

test "basic" {
    try expect(match("abc", "abc"));
    try expect(match("*", "abc"));
    try expect(match("*", ""));
    try expect(match("**", ""));
    try expect(match("*c", "abc"));
    try expect(!match("*b", "abc"));
    try expect(match("a*", "abc"));
    try expect(!match("b*", "abc"));
    try expect(match("a*", "a"));
    try expect(match("*a", "a"));
    try expect(match("a*b*c*d*e*", "axbxcxdxe"));
    try expect(match("a*b*c*d*e*", "axbxcxdxexxx"));
    try expect(match("a*b?c*x", "abxbbxdbxebxczzx"));
    try expect(!match("a*b?c*x", "abxbbxdbxebxczzy"));

    try expect(match("a/*/test", "a/foo/test"));
    try expect(!match("a/*/test", "a/foo/bar/test"));
    try expect(match("a/**/test", "a/foo/test"));
    try expect(match("a/**/test", "a/foo/bar/test"));
    try expect(match("a/**/b/c", "a/foo/bar/b/c"));
    try expect(match("a\\*b", "a*b"));
    try expect(!match("a\\*b", "axb"));

    try expect(match("[abc]", "a"));
    try expect(match("[abc]", "b"));
    try expect(match("[abc]", "c"));
    try expect(!match("[abc]", "d"));
    try expect(match("x[abc]x", "xax"));
    try expect(match("x[abc]x", "xbx"));
    try expect(match("x[abc]x", "xcx"));
    try expect(!match("x[abc]x", "xdx"));
    try expect(!match("x[abc]x", "xay"));
    try expect(match("[?]", "?"));
    try expect(!match("[?]", "a"));
    try expect(match("[*]", "*"));
    try expect(!match("[*]", "a"));

    try expect(match("[a-cx]", "a"));
    try expect(match("[a-cx]", "b"));
    try expect(match("[a-cx]", "c"));
    try expect(!match("[a-cx]", "d"));
    try expect(match("[a-cx]", "x"));

    try expect(!match("[^abc]", "a"));
    try expect(!match("[^abc]", "b"));
    try expect(!match("[^abc]", "c"));
    try expect(match("[^abc]", "d"));
    try expect(!match("[!abc]", "a"));
    try expect(!match("[!abc]", "b"));
    try expect(!match("[!abc]", "c"));
    try expect(match("[!abc]", "d"));
    try expect(match("[\\!]", "!"));

    try expect(match("a*b*[cy]*d*e*", "axbxcxdxexxx"));
    try expect(match("a*b*[cy]*d*e*", "axbxyxdxexxx"));
    try expect(match("a*b*[cy]*d*e*", "axbxxxyxdxexxx"));

    try expect(match("test.{jpg,png}", "test.jpg"));
    try expect(match("test.{jpg,png}", "test.png"));
    try expect(match("test.{j*g,p*g}", "test.jpg"));
    try expect(match("test.{j*g,p*g}", "test.jpxxxg"));
    try expect(match("test.{j*g,p*g}", "test.jxg"));
    try expect(!match("test.{j*g,p*g}", "test.jnt"));
    try expect(match("test.{j*g,j*c}", "test.jnc"));
    try expect(match("test.{jpg,p*g}", "test.png"));
    try expect(match("test.{jpg,p*g}", "test.pxg"));
    try expect(!match("test.{jpg,p*g}", "test.pnt"));
    try expect(match("test.{jpeg,png}", "test.jpeg"));
    try expect(!match("test.{jpeg,png}", "test.jpg"));
    try expect(match("test.{jpeg,png}", "test.png"));
    try expect(match("test.{jp\\,g,png}", "test.jp,g"));
    try expect(!match("test.{jp\\,g,png}", "test.jxg"));
    try expect(match("test/{foo,bar}/baz", "test/foo/baz"));
    try expect(match("test/{foo,bar}/baz", "test/bar/baz"));
    try expect(!match("test/{foo,bar}/baz", "test/baz/baz"));
    try expect(match("test/{foo*,bar*}/baz", "test/foooooo/baz"));
    try expect(match("test/{foo*,bar*}/baz", "test/barrrrr/baz"));
    try expect(match("test/{*foo,*bar}/baz", "test/xxxxfoo/baz"));
    try expect(match("test/{*foo,*bar}/baz", "test/xxxxbar/baz"));
    try expect(match("test/{foo/**,bar}/baz", "test/bar/baz"));
    try expect(!match("test/{foo/**,bar}/baz", "test/bar/test/baz"));

    try expect(!match("*.txt", "some/big/path/to/the/needle.txt"));
    try expect(match(
        "some/**/needle.{js,tsx,mdx,ts,jsx,txt}",
        "some/a/bigger/path/to/the/crazy/needle.txt",
    ));
    try expect(match(
        "some/**/{a,b,c}/**/needle.txt",
        "some/foo/a/bigger/path/to/the/crazy/needle.txt",
    ));
    try expect(!match(
        "some/**/{a,b,c}/**/needle.txt",
        "some/foo/d/bigger/path/to/the/crazy/needle.txt",
    ));
    try expect(match("a/{a{a,b},b}", "a/aa"));
    try expect(match("a/{a{a,b},b}", "a/ab"));
    try expect(!match("a/{a{a,b},b}", "a/ac"));
    try expect(match("a/{a{a,b},b}", "a/b"));
    try expect(!match("a/{a{a,b},b}", "a/c"));
    try expect(match("a/{b,c[}]*}", "a/b"));
    try expect(match("a/{b,c[}]*}", "a/c}xx"));
}

// The below tests are based on Bash and micromatch.
// https://github.com/micromatch/picomatch/blob/master/test/bash.js
test "bash" {
    try expect(!match("a*", "*"));
    try expect(!match("a*", "**"));
    try expect(!match("a*", "\\*"));
    try expect(!match("a*", "a/*"));
    try expect(!match("a*", "b"));
    try expect(!match("a*", "bc"));
    try expect(!match("a*", "bcd"));
    try expect(!match("a*", "bdir/"));
    try expect(!match("a*", "Beware"));
    try expect(match("a*", "a"));
    try expect(match("a*", "ab"));
    try expect(match("a*", "abc"));

    try expect(!match("\\a*", "*"));
    try expect(!match("\\a*", "**"));
    try expect(!match("\\a*", "\\*"));

    try expect(match("\\a*", "a"));
    try expect(!match("\\a*", "a/*"));
    try expect(match("\\a*", "abc"));
    try expect(match("\\a*", "abd"));
    try expect(match("\\a*", "abe"));
    try expect(!match("\\a*", "b"));
    try expect(!match("\\a*", "bb"));
    try expect(!match("\\a*", "bcd"));
    try expect(!match("\\a*", "bdir/"));
    try expect(!match("\\a*", "Beware"));
    try expect(!match("\\a*", "c"));
    try expect(!match("\\a*", "ca"));
    try expect(!match("\\a*", "cb"));
    try expect(!match("\\a*", "d"));
    try expect(!match("\\a*", "dd"));
    try expect(!match("\\a*", "de"));
}

test "bash directories" {
    try expect(!match("b*/", "*"));
    try expect(!match("b*/", "**"));
    try expect(!match("b*/", "\\*"));
    try expect(!match("b*/", "a"));
    try expect(!match("b*/", "a/*"));
    try expect(!match("b*/", "abc"));
    try expect(!match("b*/", "abd"));
    try expect(!match("b*/", "abe"));
    try expect(!match("b*/", "b"));
    try expect(!match("b*/", "bb"));
    try expect(!match("b*/", "bcd"));
    try expect(match("b*/", "bdir/"));
    try expect(!match("b*/", "Beware"));
    try expect(!match("b*/", "c"));
    try expect(!match("b*/", "ca"));
    try expect(!match("b*/", "cb"));
    try expect(!match("b*/", "d"));
    try expect(!match("b*/", "dd"));
    try expect(!match("b*/", "de"));
}

test "bash escaping" {
    try expect(!match("\\^", "*"));
    try expect(!match("\\^", "**"));
    try expect(!match("\\^", "\\*"));
    try expect(!match("\\^", "a"));
    try expect(!match("\\^", "a/*"));
    try expect(!match("\\^", "abc"));
    try expect(!match("\\^", "abd"));
    try expect(!match("\\^", "abe"));
    try expect(!match("\\^", "b"));
    try expect(!match("\\^", "bb"));
    try expect(!match("\\^", "bcd"));
    try expect(!match("\\^", "bdir/"));
    try expect(!match("\\^", "Beware"));
    try expect(!match("\\^", "c"));
    try expect(!match("\\^", "ca"));
    try expect(!match("\\^", "cb"));
    try expect(!match("\\^", "d"));
    try expect(!match("\\^", "dd"));
    try expect(!match("\\^", "de"));

    try expect(match("\\*", "*"));
    // try expect(match("\\*", "\\*"));
    try expect(!match("\\*", "**"));
    try expect(!match("\\*", "a"));
    try expect(!match("\\*", "a/*"));
    try expect(!match("\\*", "abc"));
    try expect(!match("\\*", "abd"));
    try expect(!match("\\*", "abe"));
    try expect(!match("\\*", "b"));
    try expect(!match("\\*", "bb"));
    try expect(!match("\\*", "bcd"));
    try expect(!match("\\*", "bdir/"));
    try expect(!match("\\*", "Beware"));
    try expect(!match("\\*", "c"));
    try expect(!match("\\*", "ca"));
    try expect(!match("\\*", "cb"));
    try expect(!match("\\*", "d"));
    try expect(!match("\\*", "dd"));
    try expect(!match("\\*", "de"));

    try expect(!match("a\\*", "*"));
    try expect(!match("a\\*", "**"));
    try expect(!match("a\\*", "\\*"));
    try expect(!match("a\\*", "a"));
    try expect(!match("a\\*", "a/*"));
    try expect(!match("a\\*", "abc"));
    try expect(!match("a\\*", "abd"));
    try expect(!match("a\\*", "abe"));
    try expect(!match("a\\*", "b"));
    try expect(!match("a\\*", "bb"));
    try expect(!match("a\\*", "bcd"));
    try expect(!match("a\\*", "bdir/"));
    try expect(!match("a\\*", "Beware"));
    try expect(!match("a\\*", "c"));
    try expect(!match("a\\*", "ca"));
    try expect(!match("a\\*", "cb"));
    try expect(!match("a\\*", "d"));
    try expect(!match("a\\*", "dd"));
    try expect(!match("a\\*", "de"));

    try expect(match("*q*", "aqa"));
    try expect(match("*q*", "aaqaa"));
    try expect(!match("*q*", "*"));
    try expect(!match("*q*", "**"));
    try expect(!match("*q*", "\\*"));
    try expect(!match("*q*", "a"));
    try expect(!match("*q*", "a/*"));
    try expect(!match("*q*", "abc"));
    try expect(!match("*q*", "abd"));
    try expect(!match("*q*", "abe"));
    try expect(!match("*q*", "b"));
    try expect(!match("*q*", "bb"));
    try expect(!match("*q*", "bcd"));
    try expect(!match("*q*", "bdir/"));
    try expect(!match("*q*", "Beware"));
    try expect(!match("*q*", "c"));
    try expect(!match("*q*", "ca"));
    try expect(!match("*q*", "cb"));
    try expect(!match("*q*", "d"));
    try expect(!match("*q*", "dd"));
    try expect(!match("*q*", "de"));

    try expect(match("\\**", "*"));
    try expect(match("\\**", "**"));
    try expect(!match("\\**", "\\*"));
    try expect(!match("\\**", "a"));
    try expect(!match("\\**", "a/*"));
    try expect(!match("\\**", "abc"));
    try expect(!match("\\**", "abd"));
    try expect(!match("\\**", "abe"));
    try expect(!match("\\**", "b"));
    try expect(!match("\\**", "bb"));
    try expect(!match("\\**", "bcd"));
    try expect(!match("\\**", "bdir/"));
    try expect(!match("\\**", "Beware"));
    try expect(!match("\\**", "c"));
    try expect(!match("\\**", "ca"));
    try expect(!match("\\**", "cb"));
    try expect(!match("\\**", "d"));
    try expect(!match("\\**", "dd"));
    try expect(!match("\\**", "de"));
}

test "bash classes" {
    try expect(!match("a*[^c]", "*"));
    try expect(!match("a*[^c]", "**"));
    try expect(!match("a*[^c]", "\\*"));
    try expect(!match("a*[^c]", "a"));
    try expect(!match("a*[^c]", "a/*"));
    try expect(!match("a*[^c]", "abc"));
    try expect(match("a*[^c]", "abd"));
    try expect(match("a*[^c]", "abe"));
    try expect(!match("a*[^c]", "b"));
    try expect(!match("a*[^c]", "bb"));
    try expect(!match("a*[^c]", "bcd"));
    try expect(!match("a*[^c]", "bdir/"));
    try expect(!match("a*[^c]", "Beware"));
    try expect(!match("a*[^c]", "c"));
    try expect(!match("a*[^c]", "ca"));
    try expect(!match("a*[^c]", "cb"));
    try expect(!match("a*[^c]", "d"));
    try expect(!match("a*[^c]", "dd"));
    try expect(!match("a*[^c]", "de"));
    try expect(!match("a*[^c]", "baz"));
    try expect(!match("a*[^c]", "bzz"));
    try expect(!match("a*[^c]", "BZZ"));
    try expect(!match("a*[^c]", "beware"));
    try expect(!match("a*[^c]", "BewAre"));

    try expect(match("a[X-]b", "a-b"));
    try expect(match("a[X-]b", "aXb"));

    try expect(!match("[a-y]*[^c]", "*"));
    try expect(match("[a-y]*[^c]", "a*"));
    try expect(!match("[a-y]*[^c]", "**"));
    try expect(!match("[a-y]*[^c]", "\\*"));
    try expect(!match("[a-y]*[^c]", "a"));
    try expect(match("[a-y]*[^c]", "a123b"));
    try expect(!match("[a-y]*[^c]", "a123c"));
    try expect(match("[a-y]*[^c]", "ab"));
    try expect(!match("[a-y]*[^c]", "a/*"));
    try expect(!match("[a-y]*[^c]", "abc"));
    try expect(match("[a-y]*[^c]", "abd"));
    try expect(match("[a-y]*[^c]", "abe"));
    try expect(!match("[a-y]*[^c]", "b"));
    try expect(match("[a-y]*[^c]", "bd"));
    try expect(match("[a-y]*[^c]", "bb"));
    try expect(match("[a-y]*[^c]", "bcd"));
    try expect(match("[a-y]*[^c]", "bdir/"));
    try expect(!match("[a-y]*[^c]", "Beware"));
    try expect(!match("[a-y]*[^c]", "c"));
    try expect(match("[a-y]*[^c]", "ca"));
    try expect(match("[a-y]*[^c]", "cb"));
    try expect(!match("[a-y]*[^c]", "d"));
    try expect(match("[a-y]*[^c]", "dd"));
    try expect(match("[a-y]*[^c]", "dd"));
    try expect(match("[a-y]*[^c]", "dd"));
    try expect(match("[a-y]*[^c]", "de"));
    try expect(match("[a-y]*[^c]", "baz"));
    try expect(match("[a-y]*[^c]", "bzz"));
    try expect(match("[a-y]*[^c]", "bzz"));
    // assert(!isMatch('bzz', '[a-y]*[^c]', { regex: true }));
    try expect(!match("[a-y]*[^c]", "BZZ"));
    try expect(match("[a-y]*[^c]", "beware"));
    try expect(!match("[a-y]*[^c]", "BewAre"));

    try expect(match("a\\*b/*", "a*b/ooo"));
    try expect(match("a\\*?/*", "a*b/ooo"));

    try expect(!match("a[b]c", "*"));
    try expect(!match("a[b]c", "**"));
    try expect(!match("a[b]c", "\\*"));
    try expect(!match("a[b]c", "a"));
    try expect(!match("a[b]c", "a/*"));
    try expect(match("a[b]c", "abc"));
    try expect(!match("a[b]c", "abd"));
    try expect(!match("a[b]c", "abe"));
    try expect(!match("a[b]c", "b"));
    try expect(!match("a[b]c", "bb"));
    try expect(!match("a[b]c", "bcd"));
    try expect(!match("a[b]c", "bdir/"));
    try expect(!match("a[b]c", "Beware"));
    try expect(!match("a[b]c", "c"));
    try expect(!match("a[b]c", "ca"));
    try expect(!match("a[b]c", "cb"));
    try expect(!match("a[b]c", "d"));
    try expect(!match("a[b]c", "dd"));
    try expect(!match("a[b]c", "de"));
    try expect(!match("a[b]c", "baz"));
    try expect(!match("a[b]c", "bzz"));
    try expect(!match("a[b]c", "BZZ"));
    try expect(!match("a[b]c", "beware"));
    try expect(!match("a[b]c", "BewAre"));

    try expect(!match("a[\"b\"]c", "*"));
    try expect(!match("a[\"b\"]c", "**"));
    try expect(!match("a[\"b\"]c", "\\*"));
    try expect(!match("a[\"b\"]c", "a"));
    try expect(!match("a[\"b\"]c", "a/*"));
    try expect(match("a[\"b\"]c", "abc"));
    try expect(!match("a[\"b\"]c", "abd"));
    try expect(!match("a[\"b\"]c", "abe"));
    try expect(!match("a[\"b\"]c", "b"));
    try expect(!match("a[\"b\"]c", "bb"));
    try expect(!match("a[\"b\"]c", "bcd"));
    try expect(!match("a[\"b\"]c", "bdir/"));
    try expect(!match("a[\"b\"]c", "Beware"));
    try expect(!match("a[\"b\"]c", "c"));
    try expect(!match("a[\"b\"]c", "ca"));
    try expect(!match("a[\"b\"]c", "cb"));
    try expect(!match("a[\"b\"]c", "d"));
    try expect(!match("a[\"b\"]c", "dd"));
    try expect(!match("a[\"b\"]c", "de"));
    try expect(!match("a[\"b\"]c", "baz"));
    try expect(!match("a[\"b\"]c", "bzz"));
    try expect(!match("a[\"b\"]c", "BZZ"));
    try expect(!match("a[\"b\"]c", "beware"));
    try expect(!match("a[\"b\"]c", "BewAre"));

    try expect(!match("a[\\\\b]c", "*"));
    try expect(!match("a[\\\\b]c", "**"));
    try expect(!match("a[\\\\b]c", "\\*"));
    try expect(!match("a[\\\\b]c", "a"));
    try expect(!match("a[\\\\b]c", "a/*"));
    try expect(match("a[\\\\b]c", "abc"));
    try expect(!match("a[\\\\b]c", "abd"));
    try expect(!match("a[\\\\b]c", "abe"));
    try expect(!match("a[\\\\b]c", "b"));
    try expect(!match("a[\\\\b]c", "bb"));
    try expect(!match("a[\\\\b]c", "bcd"));
    try expect(!match("a[\\\\b]c", "bdir/"));
    try expect(!match("a[\\\\b]c", "Beware"));
    try expect(!match("a[\\\\b]c", "c"));
    try expect(!match("a[\\\\b]c", "ca"));
    try expect(!match("a[\\\\b]c", "cb"));
    try expect(!match("a[\\\\b]c", "d"));
    try expect(!match("a[\\\\b]c", "dd"));
    try expect(!match("a[\\\\b]c", "de"));
    try expect(!match("a[\\\\b]c", "baz"));
    try expect(!match("a[\\\\b]c", "bzz"));
    try expect(!match("a[\\\\b]c", "BZZ"));
    try expect(!match("a[\\\\b]c", "beware"));
    try expect(!match("a[\\\\b]c", "BewAre"));

    try expect(!match("a[\\b]c", "*"));
    try expect(!match("a[\\b]c", "**"));
    try expect(!match("a[\\b]c", "\\*"));
    try expect(!match("a[\\b]c", "a"));
    try expect(!match("a[\\b]c", "a/*"));
    try expect(!match("a[\\b]c", "abc"));
    try expect(!match("a[\\b]c", "abd"));
    try expect(!match("a[\\b]c", "abe"));
    try expect(!match("a[\\b]c", "b"));
    try expect(!match("a[\\b]c", "bb"));
    try expect(!match("a[\\b]c", "bcd"));
    try expect(!match("a[\\b]c", "bdir/"));
    try expect(!match("a[\\b]c", "Beware"));
    try expect(!match("a[\\b]c", "c"));
    try expect(!match("a[\\b]c", "ca"));
    try expect(!match("a[\\b]c", "cb"));
    try expect(!match("a[\\b]c", "d"));
    try expect(!match("a[\\b]c", "dd"));
    try expect(!match("a[\\b]c", "de"));
    try expect(!match("a[\\b]c", "baz"));
    try expect(!match("a[\\b]c", "bzz"));
    try expect(!match("a[\\b]c", "BZZ"));
    try expect(!match("a[\\b]c", "beware"));
    try expect(!match("a[\\b]c", "BewAre"));

    try expect(!match("a[b-d]c", "*"));
    try expect(!match("a[b-d]c", "**"));
    try expect(!match("a[b-d]c", "\\*"));
    try expect(!match("a[b-d]c", "a"));
    try expect(!match("a[b-d]c", "a/*"));
    try expect(match("a[b-d]c", "abc"));
    try expect(!match("a[b-d]c", "abd"));
    try expect(!match("a[b-d]c", "abe"));
    try expect(!match("a[b-d]c", "b"));
    try expect(!match("a[b-d]c", "bb"));
    try expect(!match("a[b-d]c", "bcd"));
    try expect(!match("a[b-d]c", "bdir/"));
    try expect(!match("a[b-d]c", "Beware"));
    try expect(!match("a[b-d]c", "c"));
    try expect(!match("a[b-d]c", "ca"));
    try expect(!match("a[b-d]c", "cb"));
    try expect(!match("a[b-d]c", "d"));
    try expect(!match("a[b-d]c", "dd"));
    try expect(!match("a[b-d]c", "de"));
    try expect(!match("a[b-d]c", "baz"));
    try expect(!match("a[b-d]c", "bzz"));
    try expect(!match("a[b-d]c", "BZZ"));
    try expect(!match("a[b-d]c", "beware"));
    try expect(!match("a[b-d]c", "BewAre"));

    try expect(!match("a?c", "*"));
    try expect(!match("a?c", "**"));
    try expect(!match("a?c", "\\*"));
    try expect(!match("a?c", "a"));
    try expect(!match("a?c", "a/*"));
    try expect(match("a?c", "abc"));
    try expect(!match("a?c", "abd"));
    try expect(!match("a?c", "abe"));
    try expect(!match("a?c", "b"));
    try expect(!match("a?c", "bb"));
    try expect(!match("a?c", "bcd"));
    try expect(!match("a?c", "bdir/"));
    try expect(!match("a?c", "Beware"));
    try expect(!match("a?c", "c"));
    try expect(!match("a?c", "ca"));
    try expect(!match("a?c", "cb"));
    try expect(!match("a?c", "d"));
    try expect(!match("a?c", "dd"));
    try expect(!match("a?c", "de"));
    try expect(!match("a?c", "baz"));
    try expect(!match("a?c", "bzz"));
    try expect(!match("a?c", "BZZ"));
    try expect(!match("a?c", "beware"));
    try expect(!match("a?c", "BewAre"));

    try expect(match("*/man*/bash.*", "man/man1/bash.1"));

    try expect(match("[^a-c]*", "*"));
    try expect(match("[^a-c]*", "**"));
    try expect(!match("[^a-c]*", "a"));
    try expect(!match("[^a-c]*", "a/*"));
    try expect(!match("[^a-c]*", "abc"));
    try expect(!match("[^a-c]*", "abd"));
    try expect(!match("[^a-c]*", "abe"));
    try expect(!match("[^a-c]*", "b"));
    try expect(!match("[^a-c]*", "bb"));
    try expect(!match("[^a-c]*", "bcd"));
    try expect(!match("[^a-c]*", "bdir/"));
    try expect(match("[^a-c]*", "Beware"));
    try expect(match("[^a-c]*", "Beware"));
    try expect(!match("[^a-c]*", "c"));
    try expect(!match("[^a-c]*", "ca"));
    try expect(!match("[^a-c]*", "cb"));
    try expect(match("[^a-c]*", "d"));
    try expect(match("[^a-c]*", "dd"));
    try expect(match("[^a-c]*", "de"));
    try expect(!match("[^a-c]*", "baz"));
    try expect(!match("[^a-c]*", "bzz"));
    try expect(match("[^a-c]*", "BZZ"));
    try expect(!match("[^a-c]*", "beware"));
    try expect(match("[^a-c]*", "BewAre"));
}

test "bash wildmatch" {
    try expect(!match("a[]-]b", "aab"));
    try expect(!match("[ten]", "ten"));
    try expect(match("]", "]"));
    try expect(match("a[]-]b", "a-b"));
    try expect(match("a[]-]b", "a]b"));
    try expect(match("a[]]b", "a]b"));
    try expect(match("a[\\]a\\-]b", "aab"));
    try expect(match("t[a-g]n", "ten"));
    try expect(match("t[^a-g]n", "ton"));
}

test "bash slashmatch" {
    // try expect(!match("f[^eiu][^eiu][^eiu][^eiu][^eiu]r", "foo/bar"));
    try expect(match("foo[/]bar", "foo/bar"));
    try expect(match("f[^eiu][^eiu][^eiu][^eiu][^eiu]r", "foo-bar"));
}

test "bash extra_stars" {
    try expect(!match("a**c", "bbc"));
    try expect(match("a**c", "abc"));
    try expect(!match("a**c", "bbd"));

    try expect(!match("a***c", "bbc"));
    try expect(match("a***c", "abc"));
    try expect(!match("a***c", "bbd"));

    try expect(!match("a*****?c", "bbc"));
    try expect(match("a*****?c", "abc"));
    try expect(!match("a*****?c", "bbc"));

    try expect(match("?*****??", "bbc"));
    try expect(match("?*****??", "abc"));

    try expect(match("*****??", "bbc"));
    try expect(match("*****??", "abc"));

    try expect(match("?*****?c", "bbc"));
    try expect(match("?*****?c", "abc"));

    try expect(match("?***?****c", "bbc"));
    try expect(match("?***?****c", "abc"));
    try expect(!match("?***?****c", "bbd"));

    try expect(match("?***?****?", "bbc"));
    try expect(match("?***?****?", "abc"));

    try expect(match("?***?****", "bbc"));
    try expect(match("?***?****", "abc"));

    try expect(match("*******c", "bbc"));
    try expect(match("*******c", "abc"));

    try expect(match("*******?", "bbc"));
    try expect(match("*******?", "abc"));

    try expect(match("a*cd**?**??k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??k***", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??***k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??***k**", "abcdecdhjk"));
    try expect(match("a****c**?**??*****", "abcdecdhjk"));
}

test "stars" {
    try expect(!match("*.js", "a/b/c/z.js"));
    try expect(!match("*.js", "a/b/z.js"));
    try expect(!match("*.js", "a/z.js"));
    try expect(match("*.js", "z.js"));

    // try expect(!match("*/*", "a/.ab"));
    // try expect(!match("*", ".ab"));

    try expect(match("z*.js", "z.js"));
    try expect(match("*/*", "a/z"));
    try expect(match("*/z*.js", "a/z.js"));
    try expect(match("a/z*.js", "a/z.js"));

    try expect(match("*", "ab"));
    try expect(match("*", "abc"));

    try expect(!match("f*", "bar"));
    try expect(!match("*r", "foo"));
    try expect(!match("b*", "foo"));
    try expect(!match("*", "foo/bar"));
    try expect(match("*c", "abc"));
    try expect(match("a*", "abc"));
    try expect(match("a*c", "abc"));
    try expect(match("*r", "bar"));
    try expect(match("b*", "bar"));
    try expect(match("f*", "foo"));

    try expect(match("*abc*", "one abc two"));
    try expect(match("a*b", "a         b"));

    try expect(!match("*a*", "foo"));
    try expect(match("*a*", "bar"));
    try expect(match("*abc*", "oneabctwo"));
    try expect(!match("*-bc-*", "a-b.c-d"));
    try expect(match("*-*.*-*", "a-b.c-d"));
    try expect(match("*-b*c-*", "a-b.c-d"));
    try expect(match("*-b.c-*", "a-b.c-d"));
    try expect(match("*.*", "a-b.c-d"));
    try expect(match("*.*-*", "a-b.c-d"));
    try expect(match("*.*-d", "a-b.c-d"));
    try expect(match("*.c-*", "a-b.c-d"));
    try expect(match("*b.*d", "a-b.c-d"));
    try expect(match("a*.c*", "a-b.c-d"));
    try expect(match("a-*.*-d", "a-b.c-d"));
    try expect(match("*.*", "a.b"));
    try expect(match("*.b", "a.b"));
    try expect(match("a.*", "a.b"));
    try expect(match("a.b", "a.b"));

    try expect(!match("**-bc-**", "a-b.c-d"));
    try expect(match("**-**.**-**", "a-b.c-d"));
    try expect(match("**-b**c-**", "a-b.c-d"));
    try expect(match("**-b.c-**", "a-b.c-d"));
    try expect(match("**.**", "a-b.c-d"));
    try expect(match("**.**-**", "a-b.c-d"));
    try expect(match("**.**-d", "a-b.c-d"));
    try expect(match("**.c-**", "a-b.c-d"));
    try expect(match("**b.**d", "a-b.c-d"));
    try expect(match("a**.c**", "a-b.c-d"));
    try expect(match("a-**.**-d", "a-b.c-d"));
    try expect(match("**.**", "a.b"));
    try expect(match("**.b", "a.b"));
    try expect(match("a.**", "a.b"));
    try expect(match("a.b", "a.b"));

    try expect(match("*/*", "/ab"));
    try expect(match(".", "."));
    try expect(!match("a/", "a/.b"));
    try expect(match("/*", "/ab"));
    try expect(match("/??", "/ab"));
    try expect(match("/?b", "/ab"));
    try expect(match("/*", "/cd"));
    try expect(match("a", "a"));
    try expect(match("a/.*", "a/.b"));
    try expect(match("?/?", "a/b"));
    try expect(match("a/**/j/**/z/*.md", "a/b/c/d/e/j/n/p/o/z/c.md"));
    try expect(match("a/**/z/*.md", "a/b/c/d/e/z/c.md"));
    try expect(match("a/b/c/*.md", "a/b/c/xyz.md"));
    try expect(match("a/b/c/*.md", "a/b/c/xyz.md"));
    try expect(match("a/*/z/.a", "a/b/z/.a"));
    try expect(!match("bz", "a/b/z/.a"));
    try expect(match("a/**/c/*.md", "a/bb.bb/aa/b.b/aa/c/xyz.md"));
    try expect(match("a/**/c/*.md", "a/bb.bb/aa/bb/aa/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bb.bb/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bb/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bbbb/c/xyz.md"));
    try expect(match("*", "aaa"));
    try expect(match("*", "ab"));
    try expect(match("ab", "ab"));

    try expect(!match("*/*/*", "aaa"));
    try expect(!match("*/*/*", "aaa/bb/aa/rr"));
    try expect(!match("aaa*", "aaa/bba/ccc"));
    // try expect(!match("aaa**", "aaa/bba/ccc"));
    try expect(!match("aaa/*", "aaa/bba/ccc"));
    try expect(!match("aaa/*ccc", "aaa/bba/ccc"));
    try expect(!match("aaa/*z", "aaa/bba/ccc"));
    try expect(!match("*/*/*", "aaa/bbb"));
    try expect(!match("*/*jk*/*i", "ab/zzz/ejkl/hi"));
    try expect(match("*/*/*", "aaa/bba/ccc"));
    try expect(match("aaa/**", "aaa/bba/ccc"));
    try expect(match("aaa/*", "aaa/bbb"));
    try expect(match("*/*z*/*/*i", "ab/zzz/ejkl/hi"));
    try expect(match("*j*i", "abzzzejklhi"));

    try expect(match("*", "a"));
    try expect(match("*", "b"));
    try expect(!match("*", "a/a"));
    try expect(!match("*", "a/a/a"));
    try expect(!match("*", "a/a/b"));
    try expect(!match("*", "a/a/a/a"));
    try expect(!match("*", "a/a/a/a/a"));

    try expect(!match("*/*", "a"));
    try expect(match("*/*", "a/a"));
    try expect(!match("*/*", "a/a/a"));

    try expect(!match("*/*/*", "a"));
    try expect(!match("*/*/*", "a/a"));
    try expect(match("*/*/*", "a/a/a"));
    try expect(!match("*/*/*", "a/a/a/a"));

    try expect(!match("*/*/*/*", "a"));
    try expect(!match("*/*/*/*", "a/a"));
    try expect(!match("*/*/*/*", "a/a/a"));
    try expect(match("*/*/*/*", "a/a/a/a"));
    try expect(!match("*/*/*/*", "a/a/a/a/a"));

    try expect(!match("*/*/*/*/*", "a"));
    try expect(!match("*/*/*/*/*", "a/a"));
    try expect(!match("*/*/*/*/*", "a/a/a"));
    try expect(!match("*/*/*/*/*", "a/a/b"));
    try expect(!match("*/*/*/*/*", "a/a/a/a"));
    try expect(match("*/*/*/*/*", "a/a/a/a/a"));
    try expect(!match("*/*/*/*/*", "a/a/a/a/a/a"));

    try expect(!match("a/*", "a"));
    try expect(match("a/*", "a/a"));
    try expect(!match("a/*", "a/a/a"));
    try expect(!match("a/*", "a/a/a/a"));
    try expect(!match("a/*", "a/a/a/a/a"));

    try expect(!match("a/*/*", "a"));
    try expect(!match("a/*/*", "a/a"));
    try expect(match("a/*/*", "a/a/a"));
    try expect(!match("a/*/*", "b/a/a"));
    try expect(!match("a/*/*", "a/a/a/a"));
    try expect(!match("a/*/*", "a/a/a/a/a"));

    try expect(!match("a/*/*/*", "a"));
    try expect(!match("a/*/*/*", "a/a"));
    try expect(!match("a/*/*/*", "a/a/a"));
    try expect(match("a/*/*/*", "a/a/a/a"));
    try expect(!match("a/*/*/*", "a/a/a/a/a"));

    try expect(!match("a/*/*/*/*", "a"));
    try expect(!match("a/*/*/*/*", "a/a"));
    try expect(!match("a/*/*/*/*", "a/a/a"));
    try expect(!match("a/*/*/*/*", "a/a/b"));
    try expect(!match("a/*/*/*/*", "a/a/a/a"));
    try expect(match("a/*/*/*/*", "a/a/a/a/a"));

    try expect(!match("a/*/a", "a"));
    try expect(!match("a/*/a", "a/a"));
    try expect(match("a/*/a", "a/a/a"));
    try expect(!match("a/*/a", "a/a/b"));
    try expect(!match("a/*/a", "a/a/a/a"));
    try expect(!match("a/*/a", "a/a/a/a/a"));

    try expect(!match("a/*/b", "a"));
    try expect(!match("a/*/b", "a/a"));
    try expect(!match("a/*/b", "a/a/a"));
    try expect(match("a/*/b", "a/a/b"));
    try expect(!match("a/*/b", "a/a/a/a"));
    try expect(!match("a/*/b", "a/a/a/a/a"));

    try expect(!match("*/**/a", "a"));
    try expect(!match("*/**/a", "a/a/b"));
    try expect(match("*/**/a", "a/a"));
    try expect(match("*/**/a", "a/a/a"));
    try expect(match("*/**/a", "a/a/a/a"));
    try expect(match("*/**/a", "a/a/a/a/a"));

    try expect(!match("*/", "a"));
    try expect(!match("*/*", "a"));
    try expect(!match("a/*", "a"));
    // try expect(!match("*/*", "a/"));
    // try expect(!match("a/*", "a/"));
    try expect(!match("*", "a/a"));
    try expect(!match("*/", "a/a"));
    try expect(!match("*/", "a/x/y"));
    try expect(!match("*/*", "a/x/y"));
    try expect(!match("a/*", "a/x/y"));
    // try expect(match("*", "a/"));
    try expect(match("*", "a"));
    try expect(match("*/", "a/"));
    try expect(match("*{,/}", "a/"));
    try expect(match("*/*", "a/a"));
    try expect(match("a/*", "a/a"));

    try expect(!match("a/**/*.txt", "a.txt"));
    try expect(match("a/**/*.txt", "a/x/y.txt"));
    try expect(!match("a/**/*.txt", "a/x/y/z"));

    try expect(!match("a/*.txt", "a.txt"));
    try expect(match("a/*.txt", "a/b.txt"));
    try expect(!match("a/*.txt", "a/x/y.txt"));
    try expect(!match("a/*.txt", "a/x/y/z"));

    try expect(match("a*.txt", "a.txt"));
    try expect(!match("a*.txt", "a/b.txt"));
    try expect(!match("a*.txt", "a/x/y.txt"));
    try expect(!match("a*.txt", "a/x/y/z"));

    try expect(match("*.txt", "a.txt"));
    try expect(!match("*.txt", "a/b.txt"));
    try expect(!match("*.txt", "a/x/y.txt"));
    try expect(!match("*.txt", "a/x/y/z"));

    try expect(!match("a*", "a/b"));
    try expect(!match("a/**/b", "a/a/bb"));
    try expect(!match("a/**/b", "a/bb"));

    try expect(!match("*/**", "foo"));
    try expect(!match("**/", "foo/bar"));
    try expect(!match("**/*/", "foo/bar"));
    try expect(!match("*/*/", "foo/bar"));

    try expect(match("**/..", "/home/foo/.."));
    try expect(match("**/a", "a"));
    try expect(match("**", "a/a"));
    try expect(match("a/**", "a/a"));
    try expect(match("a/**", "a/"));
    // try expect(match("a/**", "a"));
    try expect(!match("**/", "a/a"));
    // try expect(match("**/a/**", "a"));
    // try expect(match("a/**", "a"));
    try expect(!match("**/", "a/a"));
    try expect(match("*/**/a", "a/a"));
    // try expect(match("a/**", "a"));
    try expect(match("*/**", "foo/"));
    try expect(match("**/*", "foo/bar"));
    try expect(match("*/*", "foo/bar"));
    try expect(match("*/**", "foo/bar"));
    try expect(match("**/", "foo/bar/"));
    // try expect(match("**/*", "foo/bar/"));
    try expect(match("**/*/", "foo/bar/"));
    try expect(match("*/**", "foo/bar/"));
    try expect(match("*/*/", "foo/bar/"));

    try expect(!match("*/foo", "bar/baz/foo"));
    try expect(!match("**/bar/*", "deep/foo/bar"));
    try expect(!match("*/bar/**", "deep/foo/bar/baz/x"));
    try expect(!match("/*", "ef"));
    try expect(!match("foo?bar", "foo/bar"));
    try expect(!match("**/bar*", "foo/bar/baz"));
    // try expect(!match("**/bar**", "foo/bar/baz"));
    try expect(!match("foo**bar", "foo/baz/bar"));
    try expect(!match("foo*bar", "foo/baz/bar"));
    // try expect(match("foo/**", "foo"));
    try expect(match("/*", "/ab"));
    try expect(match("/*", "/cd"));
    try expect(match("/*", "/ef"));
    try expect(match("a/**/j/**/z/*.md", "a/b/j/c/z/x.md"));
    try expect(match("a/**/j/**/z/*.md", "a/j/z/x.md"));

    try expect(match("**/foo", "bar/baz/foo"));
    try expect(match("**/bar/*", "deep/foo/bar/baz"));
    try expect(match("**/bar/**", "deep/foo/bar/baz/"));
    try expect(match("**/bar/*/*", "deep/foo/bar/baz/x"));
    try expect(match("foo/**/**/bar", "foo/b/a/z/bar"));
    try expect(match("foo/**/bar", "foo/b/a/z/bar"));
    try expect(match("foo/**/**/bar", "foo/bar"));
    try expect(match("foo/**/bar", "foo/bar"));
    try expect(match("*/bar/**", "foo/bar/baz/x"));
    try expect(match("foo/**/**/bar", "foo/baz/bar"));
    try expect(match("foo/**/bar", "foo/baz/bar"));
    try expect(match("**/foo", "XXX/foo"));
}

test "globstars" {
    try expect(match("**/*.js", "a/b/c/d.js"));
    try expect(match("**/*.js", "a/b/c.js"));
    try expect(match("**/*.js", "a/b.js"));
    try expect(match("a/b/**/*.js", "a/b/c/d/e/f.js"));
    try expect(match("a/b/**/*.js", "a/b/c/d/e.js"));
    try expect(match("a/b/c/**/*.js", "a/b/c/d.js"));
    try expect(match("a/b/**/*.js", "a/b/c/d.js"));
    try expect(match("a/b/**/*.js", "a/b/d.js"));
    try expect(!match("a/b/**/*.js", "a/d.js"));
    try expect(!match("a/b/**/*.js", "d.js"));

    try expect(!match("**c", "a/b/c"));
    try expect(!match("a/**c", "a/b/c"));
    try expect(!match("a/**z", "a/b/c"));
    try expect(!match("a/**b**/c", "a/b/c/b/c"));
    try expect(!match("a/b/c**/*.js", "a/b/c/d/e.js"));
    try expect(match("a/**/b/**/c", "a/b/c/b/c"));
    try expect(match("a/**b**/c", "a/aba/c"));
    try expect(match("a/**b**/c", "a/b/c"));
    try expect(match("a/b/c**/*.js", "a/b/c/d.js"));

    try expect(!match("a/**/*", "a"));
    try expect(!match("a/**/**/*", "a"));
    try expect(!match("a/**/**/**/*", "a"));
    try expect(!match("**/a", "a/"));
    try expect(!match("a/**/*", "a/"));
    try expect(!match("a/**/**/*", "a/"));
    try expect(!match("a/**/**/**/*", "a/"));
    try expect(!match("**/a", "a/b"));
    try expect(!match("a/**/j/**/z/*.md", "a/b/c/j/e/z/c.txt"));
    try expect(!match("a/**/b", "a/bb"));
    try expect(!match("**/a", "a/c"));
    try expect(!match("**/a", "a/b"));
    try expect(!match("**/a", "a/x/y"));
    try expect(!match("**/a", "a/b/c/d"));
    try expect(match("**", "a"));
    try expect(match("**/a", "a"));
    // try expect(match("a/**", "a"));
    try expect(match("**", "a/"));
    try expect(match("**/a/**", "a/"));
    try expect(match("a/**", "a/"));
    try expect(match("a/**/**", "a/"));
    try expect(match("**/a", "a/a"));
    try expect(match("**", "a/b"));
    try expect(match("*/*", "a/b"));
    try expect(match("a/**", "a/b"));
    try expect(match("a/**/*", "a/b"));
    try expect(match("a/**/**/*", "a/b"));
    try expect(match("a/**/**/**/*", "a/b"));
    try expect(match("a/**/b", "a/b"));
    try expect(match("**", "a/b/c"));
    try expect(match("**/*", "a/b/c"));
    try expect(match("**/**", "a/b/c"));
    try expect(match("*/**", "a/b/c"));
    try expect(match("a/**", "a/b/c"));
    try expect(match("a/**/*", "a/b/c"));
    try expect(match("a/**/**/*", "a/b/c"));
    try expect(match("a/**/**/**/*", "a/b/c"));
    try expect(match("**", "a/b/c/d"));
    try expect(match("a/**", "a/b/c/d"));
    try expect(match("a/**/*", "a/b/c/d"));
    try expect(match("a/**/**/*", "a/b/c/d"));
    try expect(match("a/**/**/**/*", "a/b/c/d"));
    try expect(match("a/b/**/c/**/*.*", "a/b/c/d.e"));
    try expect(match("a/**/f/*.md", "a/b/c/d/e/f/g.md"));
    try expect(match("a/**/f/**/k/*.md", "a/b/c/d/e/f/g/h/i/j/k/l.md"));
    try expect(match("a/b/c/*.md", "a/b/c/def.md"));
    try expect(match("a/*/c/*.md", "a/bb.bb/c/ddd.md"));
    try expect(match("a/**/f/*.md", "a/bb.bb/cc/d.d/ee/f/ggg.md"));
    try expect(match("a/**/f/*.md", "a/bb.bb/cc/dd/ee/f/ggg.md"));
    try expect(match("a/*/c/*.md", "a/bb/c/ddd.md"));
    try expect(match("a/*/c/*.md", "a/bbbb/c/ddd.md"));

    try expect(match("foo/bar/**/one/**/*.*", "foo/bar/baz/one/image.png"));
    try expect(match("foo/bar/**/one/**/*.*", "foo/bar/baz/one/two/image.png"));
    try expect(match("foo/bar/**/one/**/*.*", "foo/bar/baz/one/two/three/image.png"));
    try expect(!match("a/b/**/f", "a/b/c/d/"));
    // try expect(match("a/**", "a"));
    try expect(match("**", "a"));
    // try expect(match("a{,/**}", "a"));
    try expect(match("**", "a/"));
    try expect(match("a/**", "a/"));
    try expect(match("**", "a/b/c/d"));
    try expect(match("**", "a/b/c/d/"));
    try expect(match("**/**", "a/b/c/d/"));
    try expect(match("**/b/**", "a/b/c/d/"));
    try expect(match("a/b/**", "a/b/c/d/"));
    try expect(match("a/b/**/", "a/b/c/d/"));
    try expect(match("a/b/**/c/**/", "a/b/c/d/"));
    try expect(match("a/b/**/c/**/d/", "a/b/c/d/"));
    try expect(match("a/b/**/**/*.*", "a/b/c/d/e.f"));
    try expect(match("a/b/**/*.*", "a/b/c/d/e.f"));
    try expect(match("a/b/**/c/**/d/*.*", "a/b/c/d/e.f"));
    try expect(match("a/b/**/d/**/*.*", "a/b/c/d/e.f"));
    try expect(match("a/b/**/d/**/*.*", "a/b/c/d/g/e.f"));
    try expect(match("a/b/**/d/**/*.*", "a/b/c/d/g/g/e.f"));
    try expect(match("a/b-*/**/z.js", "a/b-c/z.js"));
    try expect(match("a/b-*/**/z.js", "a/b-c/d/e/z.js"));

    try expect(match("*/*", "a/b"));
    try expect(match("a/b/c/*.md", "a/b/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bb.bb/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bb/c/xyz.md"));
    try expect(match("a/*/c/*.md", "a/bbbb/c/xyz.md"));

    try expect(match("**/*", "a/b/c"));
    try expect(match("**/**", "a/b/c"));
    try expect(match("*/**", "a/b/c"));
    try expect(match("a/**/j/**/z/*.md", "a/b/c/d/e/j/n/p/o/z/c.md"));
    try expect(match("a/**/z/*.md", "a/b/c/d/e/z/c.md"));
    try expect(match("a/**/c/*.md", "a/bb.bb/aa/b.b/aa/c/xyz.md"));
    try expect(match("a/**/c/*.md", "a/bb.bb/aa/bb/aa/c/xyz.md"));
    try expect(!match("a/**/j/**/z/*.md", "a/b/c/j/e/z/c.txt"));
    try expect(!match("a/b/**/c{d,e}/**/xyz.md", "a/b/c/xyz.md"));
    try expect(!match("a/b/**/c{d,e}/**/xyz.md", "a/b/d/xyz.md"));
    try expect(!match("a/**/", "a/b"));
    // try expect(!match("**/*", "a/b/.js/c.txt"));
    try expect(!match("a/**/", "a/b/c/d"));
    try expect(!match("a/**/", "a/bb"));
    try expect(!match("a/**/", "a/cb"));
    try expect(match("/**", "/a/b"));
    try expect(match("**/*", "a.b"));
    try expect(match("**/*", "a.js"));
    try expect(match("**/*.js", "a.js"));
    // try expect(match("a/**/", "a/"));
    try expect(match("**/*.js", "a/a.js"));
    try expect(match("**/*.js", "a/a/b.js"));
    try expect(match("a/**/b", "a/b"));
    try expect(match("a/**b", "a/b"));
    try expect(match("**/*.md", "a/b.md"));
    try expect(match("**/*", "a/b/c.js"));
    try expect(match("**/*", "a/b/c.txt"));
    try expect(match("a/**/", "a/b/c/d/"));
    try expect(match("**/*", "a/b/c/d/a.js"));
    try expect(match("a/b/**/*.js", "a/b/c/z.js"));
    try expect(match("a/b/**/*.js", "a/b/z.js"));
    try expect(match("**/*", "ab"));
    try expect(match("**/*", "ab/c"));
    try expect(match("**/*", "ab/c/d"));
    try expect(match("**/*", "abc.js"));

    try expect(!match("**/", "a"));
    try expect(!match("**/a/*", "a"));
    try expect(!match("**/a/*/*", "a"));
    try expect(!match("*/a/**", "a"));
    try expect(!match("a/**/*", "a"));
    try expect(!match("a/**/**/*", "a"));
    try expect(!match("**/", "a/b"));
    try expect(!match("**/b/*", "a/b"));
    try expect(!match("**/b/*/*", "a/b"));
    try expect(!match("b/**", "a/b"));
    try expect(!match("**/", "a/b/c"));
    try expect(!match("**/**/b", "a/b/c"));
    try expect(!match("**/b", "a/b/c"));
    try expect(!match("**/b/*/*", "a/b/c"));
    try expect(!match("b/**", "a/b/c"));
    try expect(!match("**/", "a/b/c/d"));
    try expect(!match("**/d/*", "a/b/c/d"));
    try expect(!match("b/**", "a/b/c/d"));
    try expect(match("**", "a"));
    try expect(match("**/**", "a"));
    try expect(match("**/**/*", "a"));
    try expect(match("**/**/a", "a"));
    try expect(match("**/a", "a"));
    // try expect(match("**/a/**", "a"));
    // try expect(match("a/**", "a"));
    try expect(match("**", "a/b"));
    try expect(match("**/**", "a/b"));
    try expect(match("**/**/*", "a/b"));
    try expect(match("**/**/b", "a/b"));
    try expect(match("**/b", "a/b"));
    // try expect(match("**/b/**", "a/b"));
    // try expect(match("*/b/**", "a/b"));
    try expect(match("a/**", "a/b"));
    try expect(match("a/**/*", "a/b"));
    try expect(match("a/**/**/*", "a/b"));
    try expect(match("**", "a/b/c"));
    try expect(match("**/**", "a/b/c"));
    try expect(match("**/**/*", "a/b/c"));
    try expect(match("**/b/*", "a/b/c"));
    try expect(match("**/b/**", "a/b/c"));
    try expect(match("*/b/**", "a/b/c"));
    try expect(match("a/**", "a/b/c"));
    try expect(match("a/**/*", "a/b/c"));
    try expect(match("a/**/**/*", "a/b/c"));
    try expect(match("**", "a/b/c/d"));
    try expect(match("**/**", "a/b/c/d"));
    try expect(match("**/**/*", "a/b/c/d"));
    try expect(match("**/**/d", "a/b/c/d"));
    try expect(match("**/b/**", "a/b/c/d"));
    try expect(match("**/b/*/*", "a/b/c/d"));
    try expect(match("**/d", "a/b/c/d"));
    try expect(match("*/b/**", "a/b/c/d"));
    try expect(match("a/**", "a/b/c/d"));
    try expect(match("a/**/*", "a/b/c/d"));
    try expect(match("a/**/**/*", "a/b/c/d"));
}

test "utf8" {
    try expect(match("フ*/**/*", "フォルダ/aaa.js"));
    try expect(match("フォ*/**/*", "フォルダ/aaa.js"));
    try expect(match("フォル*/**/*", "フォルダ/aaa.js"));
    try expect(match("フ*ル*/**/*", "フォルダ/aaa.js"));
    try expect(match("フォルダ/**/*", "フォルダ/aaa.js"));
}

test "negation" {
    try expect(!match("!*", "abc"));
    try expect(!match("!abc", "abc"));
    try expect(!match("*!.md", "bar.md"));
    try expect(!match("foo!.md", "bar.md"));
    try expect(!match("\\!*!*.md", "foo!.md"));
    try expect(!match("\\!*!*.md", "foo!bar.md"));
    try expect(match("*!*.md", "!foo!.md"));
    try expect(match("\\!*!*.md", "!foo!.md"));
    try expect(match("!*foo", "abc"));
    try expect(match("!foo*", "abc"));
    try expect(match("!xyz", "abc"));
    try expect(match("*!*.*", "ba!r.js"));
    try expect(match("*.md", "bar.md"));
    try expect(match("*!*.*", "foo!.md"));
    try expect(match("*!*.md", "foo!.md"));
    try expect(match("*!.md", "foo!.md"));
    try expect(match("*.md", "foo!.md"));
    try expect(match("foo!.md", "foo!.md"));
    try expect(match("*!*.md", "foo!bar.md"));
    try expect(match("*b*.md", "foobar.md"));

    try expect(!match("a!!b", "a"));
    try expect(!match("a!!b", "aa"));
    try expect(!match("a!!b", "a/b"));
    try expect(!match("a!!b", "a!b"));
    try expect(match("a!!b", "a!!b"));
    try expect(!match("a!!b", "a/!!/b"));

    try expect(!match("!a/b", "a/b"));
    try expect(match("!a/b", "a"));
    try expect(match("!a/b", "a.b"));
    try expect(match("!a/b", "a/a"));
    try expect(match("!a/b", "a/c"));
    try expect(match("!a/b", "b/a"));
    try expect(match("!a/b", "b/b"));
    try expect(match("!a/b", "b/c"));

    try expect(!match("!abc", "abc"));
    try expect(match("!!abc", "abc"));
    try expect(!match("!!!abc", "abc"));
    try expect(match("!!!!abc", "abc"));
    try expect(!match("!!!!!abc", "abc"));
    try expect(match("!!!!!!abc", "abc"));
    try expect(!match("!!!!!!!abc", "abc"));
    try expect(match("!!!!!!!!abc", "abc"));

    // try expect(!match("!(*/*)", "a/a"));
    // try expect(!match("!(*/*)", "a/b"));
    // try expect(!match("!(*/*)", "a/c"));
    // try expect(!match("!(*/*)", "b/a"));
    // try expect(!match("!(*/*)", "b/b"));
    // try expect(!match("!(*/*)", "b/c"));
    // try expect(!match("!(*/b)", "a/b"));
    // try expect(!match("!(*/b)", "b/b"));
    // try expect(!match("!(a/b)", "a/b"));
    try expect(!match("!*", "a"));
    try expect(!match("!*", "a.b"));
    try expect(!match("!*/*", "a/a"));
    try expect(!match("!*/*", "a/b"));
    try expect(!match("!*/*", "a/c"));
    try expect(!match("!*/*", "b/a"));
    try expect(!match("!*/*", "b/b"));
    try expect(!match("!*/*", "b/c"));
    try expect(!match("!*/b", "a/b"));
    try expect(!match("!*/b", "b/b"));
    try expect(!match("!*/c", "a/c"));
    try expect(!match("!*/c", "a/c"));
    try expect(!match("!*/c", "b/c"));
    try expect(!match("!*/c", "b/c"));
    try expect(!match("!*a*", "bar"));
    try expect(!match("!*a*", "fab"));
    // try expect(!match("!a/(*)", "a/a"));
    // try expect(!match("!a/(*)", "a/b"));
    // try expect(!match("!a/(*)", "a/c"));
    // try expect(!match("!a/(b)", "a/b"));
    try expect(!match("!a/*", "a/a"));
    try expect(!match("!a/*", "a/b"));
    try expect(!match("!a/*", "a/c"));
    try expect(!match("!f*b", "fab"));
    // try expect(match("!(*/*)", "a"));
    // try expect(match("!(*/*)", "a.b"));
    // try expect(match("!(*/b)", "a"));
    // try expect(match("!(*/b)", "a.b"));
    // try expect(match("!(*/b)", "a/a"));
    // try expect(match("!(*/b)", "a/c"));
    // try expect(match("!(*/b)", "b/a"));
    // try expect(match("!(*/b)", "b/c"));
    // try expect(match("!(a/b)", "a"));
    // try expect(match("!(a/b)", "a.b"));
    // try expect(match("!(a/b)", "a/a"));
    // try expect(match("!(a/b)", "a/c"));
    // try expect(match("!(a/b)", "b/a"));
    // try expect(match("!(a/b)", "b/b"));
    // try expect(match("!(a/b)", "b/c"));
    try expect(match("!*", "a/a"));
    try expect(match("!*", "a/b"));
    try expect(match("!*", "a/c"));
    try expect(match("!*", "b/a"));
    try expect(match("!*", "b/b"));
    try expect(match("!*", "b/c"));
    try expect(match("!*/*", "a"));
    try expect(match("!*/*", "a.b"));
    try expect(match("!*/b", "a"));
    try expect(match("!*/b", "a.b"));
    try expect(match("!*/b", "a/a"));
    try expect(match("!*/b", "a/c"));
    try expect(match("!*/b", "b/a"));
    try expect(match("!*/b", "b/c"));
    try expect(match("!*/c", "a"));
    try expect(match("!*/c", "a.b"));
    try expect(match("!*/c", "a/a"));
    try expect(match("!*/c", "a/b"));
    try expect(match("!*/c", "b/a"));
    try expect(match("!*/c", "b/b"));
    try expect(match("!*a*", "foo"));
    // try expect(match("!a/(*)", "a"));
    // try expect(match("!a/(*)", "a.b"));
    // try expect(match("!a/(*)", "b/a"));
    // try expect(match("!a/(*)", "b/b"));
    // try expect(match("!a/(*)", "b/c"));
    // try expect(match("!a/(b)", "a"));
    // try expect(match("!a/(b)", "a.b"));
    // try expect(match("!a/(b)", "a/a"));
    // try expect(match("!a/(b)", "a/c"));
    // try expect(match("!a/(b)", "b/a"));
    // try expect(match("!a/(b)", "b/b"));
    // try expect(match("!a/(b)", "b/c"));
    try expect(match("!a/*", "a"));
    try expect(match("!a/*", "a.b"));
    try expect(match("!a/*", "b/a"));
    try expect(match("!a/*", "b/b"));
    try expect(match("!a/*", "b/c"));
    try expect(match("!f*b", "bar"));
    try expect(match("!f*b", "foo"));

    try expect(!match("!.md", ".md"));
    try expect(match("!**/*.md", "a.js"));
    // try expect(!match("!**/*.md", "b.md"));
    try expect(match("!**/*.md", "c.txt"));
    try expect(match("!*.md", "a.js"));
    try expect(!match("!*.md", "b.md"));
    try expect(match("!*.md", "c.txt"));
    try expect(!match("!*.md", "abc.md"));
    try expect(match("!*.md", "abc.txt"));
    try expect(!match("!*.md", "foo.md"));
    try expect(match("!.md", "foo.md"));

    try expect(match("!*.md", "a.js"));
    try expect(match("!*.md", "b.txt"));
    try expect(!match("!*.md", "c.md"));
    try expect(!match("!a/*/a.js", "a/a/a.js"));
    try expect(!match("!a/*/a.js", "a/b/a.js"));
    try expect(!match("!a/*/a.js", "a/c/a.js"));
    try expect(!match("!a/*/*/a.js", "a/a/a/a.js"));
    try expect(match("!a/*/*/a.js", "b/a/b/a.js"));
    try expect(match("!a/*/*/a.js", "c/a/c/a.js"));
    try expect(!match("!a/a*.txt", "a/a.txt"));
    try expect(match("!a/a*.txt", "a/b.txt"));
    try expect(match("!a/a*.txt", "a/c.txt"));
    try expect(!match("!a.a*.txt", "a.a.txt"));
    try expect(match("!a.a*.txt", "a.b.txt"));
    try expect(match("!a.a*.txt", "a.c.txt"));
    try expect(!match("!a/*.txt", "a/a.txt"));
    try expect(!match("!a/*.txt", "a/b.txt"));
    try expect(!match("!a/*.txt", "a/c.txt"));

    try expect(match("!*.md", "a.js"));
    try expect(match("!*.md", "b.txt"));
    try expect(!match("!*.md", "c.md"));
    // try expect(!match("!**/a.js", "a/a/a.js"));
    // try expect(!match("!**/a.js", "a/b/a.js"));
    // try expect(!match("!**/a.js", "a/c/a.js"));
    try expect(match("!**/a.js", "a/a/b.js"));
    try expect(!match("!a/**/a.js", "a/a/a/a.js"));
    try expect(match("!a/**/a.js", "b/a/b/a.js"));
    try expect(match("!a/**/a.js", "c/a/c/a.js"));
    try expect(match("!**/*.md", "a/b.js"));
    try expect(match("!**/*.md", "a.js"));
    try expect(!match("!**/*.md", "a/b.md"));
    // try expect(!match("!**/*.md", "a.md"));
    try expect(!match("**/*.md", "a/b.js"));
    try expect(!match("**/*.md", "a.js"));
    try expect(match("**/*.md", "a/b.md"));
    try expect(match("**/*.md", "a.md"));
    try expect(match("!**/*.md", "a/b.js"));
    try expect(match("!**/*.md", "a.js"));
    try expect(!match("!**/*.md", "a/b.md"));
    // try expect(!match("!**/*.md", "a.md"));
    try expect(match("!*.md", "a/b.js"));
    try expect(match("!*.md", "a.js"));
    try expect(match("!*.md", "a/b.md"));
    try expect(!match("!*.md", "a.md"));
    try expect(match("!**/*.md", "a.js"));
    // try expect(!match("!**/*.md", "b.md"));
    try expect(match("!**/*.md", "c.txt"));
}

test "question_mark" {
    try expect(match("?", "a"));
    try expect(!match("?", "aa"));
    try expect(!match("?", "ab"));
    try expect(!match("?", "aaa"));
    try expect(!match("?", "abcdefg"));

    try expect(!match("??", "a"));
    try expect(match("??", "aa"));
    try expect(match("??", "ab"));
    try expect(!match("??", "aaa"));
    try expect(!match("??", "abcdefg"));

    try expect(!match("???", "a"));
    try expect(!match("???", "aa"));
    try expect(!match("???", "ab"));
    try expect(match("???", "aaa"));
    try expect(!match("???", "abcdefg"));

    try expect(!match("a?c", "aaa"));
    try expect(match("a?c", "aac"));
    try expect(match("a?c", "abc"));
    try expect(!match("ab?", "a"));
    try expect(!match("ab?", "aa"));
    try expect(!match("ab?", "ab"));
    try expect(!match("ab?", "ac"));
    try expect(!match("ab?", "abcd"));
    try expect(!match("ab?", "abbb"));
    try expect(match("a?b", "acb"));

    try expect(!match("a/?/c/?/e.md", "a/bb/c/dd/e.md"));
    try expect(match("a/??/c/??/e.md", "a/bb/c/dd/e.md"));
    try expect(!match("a/??/c.md", "a/bbb/c.md"));
    try expect(match("a/?/c.md", "a/b/c.md"));
    try expect(match("a/?/c/?/e.md", "a/b/c/d/e.md"));
    try expect(!match("a/?/c/???/e.md", "a/b/c/d/e.md"));
    try expect(match("a/?/c/???/e.md", "a/b/c/zzz/e.md"));
    try expect(!match("a/?/c.md", "a/bb/c.md"));
    try expect(match("a/??/c.md", "a/bb/c.md"));
    try expect(match("a/???/c.md", "a/bbb/c.md"));
    try expect(match("a/????/c.md", "a/bbbb/c.md"));
}

test "braces" {
    try expect(match("{a,b,c}", "a"));
    try expect(match("{a,b,c}", "b"));
    try expect(match("{a,b,c}", "c"));
    try expect(!match("{a,b,c}", "aa"));
    try expect(!match("{a,b,c}", "bb"));
    try expect(!match("{a,b,c}", "cc"));

    try expect(match("a/{a,b}", "a/a"));
    try expect(match("a/{a,b}", "a/b"));
    try expect(!match("a/{a,b}", "a/c"));
    try expect(!match("a/{a,b}", "b/b"));
    try expect(!match("a/{a,b,c}", "b/b"));
    try expect(match("a/{a,b,c}", "a/c"));
    try expect(match("a{b,bc}.txt", "abc.txt"));

    try expect(match("foo[{a,b}]baz", "foo{baz"));

    try expect(!match("a{,b}.txt", "abc.txt"));
    try expect(!match("a{a,b,}.txt", "abc.txt"));
    try expect(!match("a{b,}.txt", "abc.txt"));
    try expect(match("a{,b}.txt", "a.txt"));
    try expect(match("a{b,}.txt", "a.txt"));
    try expect(match("a{a,b,}.txt", "aa.txt"));
    try expect(match("a{a,b,}.txt", "aa.txt"));
    try expect(match("a{,b}.txt", "ab.txt"));
    try expect(match("a{b,}.txt", "ab.txt"));

    // try expect(match("{a/,}a/**", "a"));
    try expect(match("a{a,b/}*.txt", "aa.txt"));
    try expect(match("a{a,b/}*.txt", "ab/.txt"));
    try expect(match("a{a,b/}*.txt", "ab/a.txt"));
    // try expect(match("{a/,}a/**", "a/"));
    try expect(match("{a/,}a/**", "a/a/"));
    // try expect(match("{a/,}a/**", "a/a"));
    try expect(match("{a/,}a/**", "a/a/a"));
    try expect(match("{a/,}a/**", "a/a/"));
    try expect(match("{a/,}a/**", "a/a/a/"));
    try expect(match("{a/,}b/**", "a/b/a/"));
    try expect(match("{a/,}b/**", "b/a/"));
    try expect(match("a{,/}*.txt", "a.txt"));
    try expect(match("a{,/}*.txt", "ab.txt"));
    try expect(match("a{,/}*.txt", "a/b.txt"));
    try expect(match("a{,/}*.txt", "a/ab.txt"));

    try expect(match("a{,.*{foo,db},\\(bar\\)}.txt", "a.txt"));
    try expect(!match("a{,.*{foo,db},\\(bar\\)}.txt", "adb.txt"));
    try expect(match("a{,.*{foo,db},\\(bar\\)}.txt", "a.db.txt"));

    try expect(match("a{,*.{foo,db},\\(bar\\)}.txt", "a.txt"));
    try expect(!match("a{,*.{foo,db},\\(bar\\)}.txt", "adb.txt"));
    try expect(match("a{,*.{foo,db},\\(bar\\)}.txt", "a.db.txt"));

    // try expect(match("a{,.*{foo,db},\\(bar\\)}", "a"));
    try expect(!match("a{,.*{foo,db},\\(bar\\)}", "adb"));
    try expect(match("a{,.*{foo,db},\\(bar\\)}", "a.db"));

    // try expect(match("a{,*.{foo,db},\\(bar\\)}", "a"));
    try expect(!match("a{,*.{foo,db},\\(bar\\)}", "adb"));
    try expect(match("a{,*.{foo,db},\\(bar\\)}", "a.db"));

    try expect(!match("{,.*{foo,db},\\(bar\\)}", "a"));
    try expect(!match("{,.*{foo,db},\\(bar\\)}", "adb"));
    try expect(!match("{,.*{foo,db},\\(bar\\)}", "a.db"));
    try expect(match("{,.*{foo,db},\\(bar\\)}", ".db"));

    try expect(!match("{,*.{foo,db},\\(bar\\)}", "a"));
    try expect(match("{*,*.{foo,db},\\(bar\\)}", "a"));
    try expect(!match("{,*.{foo,db},\\(bar\\)}", "adb"));
    try expect(match("{,*.{foo,db},\\(bar\\)}", "a.db"));

    try expect(!match("a/b/**/c{d,e}/**/xyz.md", "a/b/c/xyz.md"));
    try expect(!match("a/b/**/c{d,e}/**/xyz.md", "a/b/d/xyz.md"));
    try expect(match("a/b/**/c{d,e}/**/xyz.md", "a/b/cd/xyz.md"));
    try expect(match("a/b/**/{c,d,e}/**/xyz.md", "a/b/c/xyz.md"));
    try expect(match("a/b/**/{c,d,e}/**/xyz.md", "a/b/d/xyz.md"));
    try expect(match("a/b/**/{c,d,e}/**/xyz.md", "a/b/e/xyz.md"));

    try expect(match("*{a,b}*", "xax"));
    try expect(match("*{a,b}*", "xxax"));
    try expect(match("*{a,b}*", "xbx"));

    try expect(match("*{*a,b}", "xba"));
    try expect(match("*{*a,b}", "xb"));

    try expect(!match("*??", "a"));
    try expect(!match("*???", "aa"));
    try expect(match("*???", "aaa"));
    try expect(!match("*****??", "a"));
    try expect(!match("*****???", "aa"));
    try expect(match("*****???", "aaa"));

    try expect(!match("a*?c", "aaa"));
    try expect(match("a*?c", "aac"));
    try expect(match("a*?c", "abc"));

    try expect(match("a**?c", "abc"));
    try expect(!match("a**?c", "abb"));
    try expect(match("a**?c", "acc"));
    try expect(match("a*****?c", "abc"));

    try expect(match("*****?", "a"));
    try expect(match("*****?", "aa"));
    try expect(match("*****?", "abc"));
    try expect(match("*****?", "zzz"));
    try expect(match("*****?", "bbb"));
    try expect(match("*****?", "aaaa"));

    try expect(!match("*****??", "a"));
    try expect(match("*****??", "aa"));
    try expect(match("*****??", "abc"));
    try expect(match("*****??", "zzz"));
    try expect(match("*****??", "bbb"));
    try expect(match("*****??", "aaaa"));

    try expect(!match("?*****??", "a"));
    try expect(!match("?*****??", "aa"));
    try expect(match("?*****??", "abc"));
    try expect(match("?*****??", "zzz"));
    try expect(match("?*****??", "bbb"));
    try expect(match("?*****??", "aaaa"));

    try expect(match("?*****?c", "abc"));
    try expect(!match("?*****?c", "abb"));
    try expect(!match("?*****?c", "zzz"));

    try expect(match("?***?****c", "abc"));
    try expect(!match("?***?****c", "bbb"));
    try expect(!match("?***?****c", "zzz"));

    try expect(match("?***?****?", "abc"));
    try expect(match("?***?****?", "bbb"));
    try expect(match("?***?****?", "zzz"));

    try expect(match("?***?****", "abc"));
    try expect(match("*******c", "abc"));
    try expect(match("*******?", "abc"));
    try expect(match("a*cd**?**??k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??k***", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??***k", "abcdecdhjk"));
    try expect(match("a**?**cd**?**??***k**", "abcdecdhjk"));
    try expect(match("a****c**?**??*****", "abcdecdhjk"));

    try expect(!match("a/?/c/?/*/e.md", "a/b/c/d/e.md"));
    try expect(match("a/?/c/?/*/e.md", "a/b/c/d/e/e.md"));
    try expect(match("a/?/c/?/*/e.md", "a/b/c/d/efghijk/e.md"));
    try expect(match("a/?/**/e.md", "a/b/c/d/efghijk/e.md"));
    try expect(!match("a/?/e.md", "a/bb/e.md"));
    try expect(match("a/??/e.md", "a/bb/e.md"));
    try expect(!match("a/?/**/e.md", "a/bb/e.md"));
    try expect(match("a/?/**/e.md", "a/b/ccc/e.md"));
    try expect(match("a/*/?/**/e.md", "a/b/c/d/efghijk/e.md"));
    try expect(match("a/*/?/**/e.md", "a/b/c/d/efgh.ijk/e.md"));
    try expect(match("a/*/?/**/e.md", "a/b.bb/c/d/efgh.ijk/e.md"));
    try expect(match("a/*/?/**/e.md", "a/bbb/c/d/efgh.ijk/e.md"));

    try expect(match("a/*/ab??.md", "a/bbb/abcd.md"));
    try expect(match("a/bbb/ab??.md", "a/bbb/abcd.md"));
    try expect(match("a/bbb/ab???md", "a/bbb/abcd.md"));
}

fn matchSame(str: []const u8) bool {
    return match(str, str);
}
test "fuzz_tests" {
    // https://github.com/devongovett/glob-match/issues/1
    try expect(!matchSame(
        "{*{??*{??**,Uz*zz}w**{*{**a,z***b*[!}w??*azzzzzzzz*!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!z[za,z&zz}w**z*z*}",
    ));
    try expect(!matchSame(
        "**** *{*{??*{??***\x05 *{*{??*{??***0x5,\x00U\x00}]*****0x1,\x00***\x00,\x00\x00}w****,\x00U\x00}]*****0x1,\x00***\x00,\x00\x00}w*****0x1***{}*.*\x00\x00*\x00",
    ));
}
