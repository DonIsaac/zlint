const std = @import("std");
const Bitflags = @import("./bitflags.zig").Bitflags;

const expectEqual = std.testing.expectEqual;
const expectFmt = std.testing.expectFmt;
const expect = std.testing.expect;

const TestFlags = packed struct {
    a: bool = false,
    b: bool = false,
    c: bool = false,
    d: bool = false,

    const BitflagsMixin = Bitflags(@This());
    pub const Flag = BitflagsMixin.Flag;
    pub const Repr = BitflagsMixin.Repr;
    pub const empty = BitflagsMixin.empty;
    pub const all = BitflagsMixin.all;
    pub const isEmpty = BitflagsMixin.isEmpty;
    pub const intersects = BitflagsMixin.intersects;
    pub const contains = BitflagsMixin.contains;
    pub const merge = BitflagsMixin.merge;
    pub const set = BitflagsMixin.set;
    pub const not = BitflagsMixin.not;
    pub const eql = BitflagsMixin.eql;
    pub const repr = BitflagsMixin.repr;
    pub const format = BitflagsMixin.format;
    pub const jsonStringify = BitflagsMixin.jsonStringify;
};

const PaddedFlags = packed struct(u8) {
    a: bool = false,
    b: bool = false,
    c: bool = false,
    d: bool = false,
    _: u4 = 0,

    const BitflagsMixin = Bitflags(@This());
    pub const Flag = BitflagsMixin.Flag;
    pub const Repr = BitflagsMixin.Repr;
    pub const empty = BitflagsMixin.empty;
    pub const all = BitflagsMixin.all;
    pub const isEmpty = BitflagsMixin.isEmpty;
    pub const intersects = BitflagsMixin.intersects;
    pub const contains = BitflagsMixin.contains;
    pub const merge = BitflagsMixin.merge;
    pub const set = BitflagsMixin.set;
    pub const not = BitflagsMixin.not;
    pub const eql = BitflagsMixin.eql;
    pub const repr = BitflagsMixin.repr;
    pub const format = BitflagsMixin.format;
    pub const jsonStringify = BitflagsMixin.jsonStringify;
};

test "Bitflags.isEmpty" {
    try expectEqual(TestFlags{}, TestFlags.empty);
    try expect(TestFlags.empty.isEmpty());
    try expect(!(TestFlags{ .a = true }).isEmpty());
}

test "Bitflags.all" {
    const expected: TestFlags = .{ .a = true, .b = true, .c = true, .d = true };
    try expectEqual(expected, TestFlags.all);
    try expect(TestFlags.all.eql(expected));
}

test "Bitflags.intersects" {
    const ab: TestFlags = .{ .a = true, .b = true };
    const bc: TestFlags = .{ .b = true, .c = true };

    try expect(ab.intersects(ab));
    try expect(ab.intersects(bc));
    try expect(ab.intersects(.{ .a = true }));
    // TODO: should this be true?
    // try expect(ab.intersects(TestFlags.empty));
    try expect(!ab.intersects(.{ .c = true }));
}

test "Bitflags.contains" {}

test "Bitflags.merge" {
    const a = TestFlags{ .a = true };
    const b = TestFlags{ .b = true };
    const empty = TestFlags{};

    try expectEqual(TestFlags{ .a = true, .b = true }, a.merge(b));
    try expectEqual(a, a.merge(empty));
    try expectEqual(a, a.merge(a));
    try expectEqual(a, a.merge(.{ .a = false }));

    // does not mutate
    try expectEqual(TestFlags{ .a = true }, a);
    try expectEqual(TestFlags{ .b = true }, b);
    try expectEqual(TestFlags{}, empty);
}

test "Bitflags.set" {
    var f = TestFlags{ .a = true, .c = true };
    const initial = f;

    f.set(.{ .b = true }, false);
    try expectEqual(initial, f);

    f.set(.{ .a = true }, true);
    try expectEqual(initial, f);

    f.set(.{ .a = true, .b = true, .c = false }, false);
    try expectEqual(TestFlags{ .c = true }, f);
}

test "Bitflags.not" {
    inline for (.{ TestFlags, PaddedFlags }) |Flags| {
        const ab: Flags = .{ .a = true, .b = true };
        const cd = Flags{ .c = true, .d = true };
        try expectEqual(cd, ab.not());
        try expectEqual(ab, cd.not());
        try expectEqual(ab, ab.not().not());
        try expectEqual(TestFlags.all, TestFlags.empty.not());
        try expectEqual(TestFlags.empty, TestFlags.all.not());
    }
}

test "Bitflags.format" {
    const empty = TestFlags{};
    const some = TestFlags{ .a = true, .c = true };
    const all = TestFlags{ .a = true, .b = true, .c = true, .d = true };
    try expectFmt("0", "{d}", .{empty});
    const name = "util.bitflags_test.TestFlags";
    try expectFmt(name ++ "()", "{f}", .{empty});
    try expectFmt(name ++ "(a | c)", "{f}", .{some});
    try expectFmt(name ++ "(a | b | c | d)", "{f}", .{all});
}
