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

    const ThisFlags = Bitflags(@This());
    pub const Flag = ThisFlags.Flag;
    pub const Repr = ThisFlags.Repr;
    pub const all = ThisFlags.all;
    pub const contains = ThisFlags.contains;
    pub const empty = ThisFlags.empty;
    pub const eql = ThisFlags.eql;
    pub const format = ThisFlags.format;
    pub const formatNumber = ThisFlags.formatNumber;
    pub const intersects = ThisFlags.intersects;
    pub const isEmpty = ThisFlags.isEmpty;
    pub const jsonStringify = ThisFlags.jsonStringify;
    pub const merge = ThisFlags.merge;
    pub const not = ThisFlags.not;
    pub const repr = ThisFlags.repr;
    pub const set = ThisFlags.set;
};

const PaddedFlags = packed struct(u8) {
    a: bool = false,
    b: bool = false,
    c: bool = false,
    d: bool = false,
    _: u4 = 0,

    const ThisFlags = Bitflags(@This());
    pub const Flag = ThisFlags.Flag;
    pub const Repr = ThisFlags.Repr;
    pub const jsonStringify = ThisFlags.jsonStringify;
    pub const format = ThisFlags.format;
    pub const formatNumber = ThisFlags.formatNumber;
    pub const eql = ThisFlags.eql;
    pub const intersects = ThisFlags.intersects;
    pub const contains = ThisFlags.contains;
    pub const merge = ThisFlags.merge;
    pub const set = ThisFlags.set;
    pub const not = ThisFlags.not;
    pub const repr = ThisFlags.repr;
    pub const empty = ThisFlags.empty;
    pub const isEmpty = ThisFlags.isEmpty;
    pub const all = ThisFlags.all;
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
    const name = "bitflags_test.TestFlags";
    try expectFmt(name ++ "()", "{f}", .{empty});
    try expectFmt(name ++ "(a | c)", "{f}", .{some});
    try expectFmt(name ++ "(a | b | c | d)", "{f}", .{all});
}
