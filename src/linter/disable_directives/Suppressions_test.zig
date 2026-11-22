const std = @import("std");
const Suppressions = @import("./Suppressions.zig");
const Rule = @import("../rule.zig").Rule;
const Semantic = @import("../../Semantic.zig");
const build = @import("../../Semantic/test/util.zig").build;

const t = std.testing;

fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n:0]u8 {
    comptime {
        var out: [s.len * n:0]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        out[s.len * n] = 0;
        const final = out;
        return &final;
    }
}

const unsafe_undefined = Rule.getIdFor("unsafe-undefined").?;
const unused_decls = Rule.getIdFor("unused-decls").?;

const Fixture = struct {
    sema: Semantic,
    s: Suppressions,

    fn init(source: [:0]const u8) !Fixture {
        var sema = try build(source);
        errdefer sema.deinit();
        return .{ .sema = sema, .s = try .init(t.allocator, &sema) };
    }

    fn deinit(self: *Fixture) void {
        self.s.deinit(t.allocator);
        self.sema.deinit();
        self.* = undefined;
    }
};

/// Byte offset of the first occurrence of `needle` in `source`.
fn at(source: []const u8, needle: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, source, needle).?);
}

test "no directives" {
    const source = "const x = 1;\n// just a comment\nconst y = 2;";
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(0, s.global.count());
    try t.expectEqual(0, s.lines.len);
    try t.expect(!s.isSuppressed(unsafe_undefined, 0));
}

test "global directives are merged" {
    const source =
        \\//! zlint-disable unused-decls
        \\// zlint-disable unsafe-undefined
        \\// zlint-disable not-a-rule
        \\// zlint-disable 42
        \\const x = 1;
        \\// zlint-disable
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(2, s.global.count());
    try t.expect(s.global.isSet(unsafe_undefined.int()));
    try t.expect(s.global.isSet(unused_decls.int()));
    try t.expectEqual(0, s.lines.len);
}

test "global directives with all rules" {
    const source =
        \\// zlint-disable
        \\const x = 1;
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(Suppressions.RuleMask.full, s.global);
}

test "repeated rule names do not overflow" {
    const source = "// zlint-disable" ++ comptime repeat(" unsafe-undefined", 512) ++ "\nconst x = 1;";
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(1, s.global.count());
    try t.expect(s.global.isSet(unsafe_undefined.int()));
}

test "zlint-disable-next-line" {
    const source =
        \\const a = 1;
        \\// zlint-disable-next-line unsafe-undefined
        \\const b = undefined;
        \\const c = undefined;
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(1, s.lines.len);
    const b = at(source, "const b");
    const b_end = at(source, "\nconst c");
    try t.expect(s.isSuppressed(unsafe_undefined, b));
    try t.expect(s.isSuppressed(unsafe_undefined, b_end));
    try t.expect(!s.isSuppressed(unused_decls, b));
    // neither the directive's own line nor the line after the target
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "// zlint")));
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const c")));
    try t.expect(!s.isSuppressed(unsafe_undefined, 0));
}

test "zlint-disable-line" {
    const source =
        \\const a = undefined;
        \\const b = undefined; // zlint-disable-line
        \\const c = undefined;
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(1, s.lines.len);
    try t.expect(s.isSuppressed(unsafe_undefined, at(source, "const b")));
    try t.expect(s.isSuppressed(unused_decls, at(source, "undefined; //")));
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const a")));
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const c")));
}

test "directives on the first and last lines" {
    const source = "const a = 1; // zlint-disable-line unsafe-undefined\nconst b = 1;\n// zlint-disable-next-line\nconst c = 1;";
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(2, s.lines.len);
    try t.expect(s.isSuppressed(unsafe_undefined, 0));
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const b")));
    try t.expect(s.isSuppressed(unused_decls, at(source, "const c")));
    try t.expect(s.isSuppressed(unused_decls, @intCast(source.len)));
}

test "zlint-disable-next-line at end of file" {
    inline for (.{ "const a = 1;\n// zlint-disable-next-line", "const a = 1;\n// zlint-disable-next-line\n" }) |source| {
        var f: Fixture = try .init(source);
        defer f.deinit();
        const s = &f.s;
        try t.expect(!s.isSuppressed(unsafe_undefined, 0));
        try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "// zlint")));
    }
}

test "CRLF line endings" {
    const source = "const a = 1;\r\n// zlint-disable-next-line\r\nconst b = 1;\r\nconst c = 1; // zlint-disable-line\r\nconst d = 1;\r\n";
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const a")));
    try t.expect(s.isSuppressed(unsafe_undefined, at(source, "const b")));
    try t.expect(s.isSuppressed(unsafe_undefined, at(source, "const c")));
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const d")));
}

test "multiple directives targeting the same line" {
    const source =
        \\// zlint-disable-next-line unsafe-undefined
        \\const a = undefined; // zlint-disable-line unused-decls
        \\const b = undefined;
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(2, s.lines.len);
    const a = at(source, "const a");
    try t.expect(s.isSuppressed(unsafe_undefined, a));
    try t.expect(s.isSuppressed(unused_decls, a));
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const b")));
}

test "line directives with only unknown rules suppress nothing" {
    const source =
        \\// zlint-disable-next-line not-a-rule
        \\const a = undefined; // zlint-disable-line #123
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(0, s.lines.len);
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const a")));
}

test "line directives are not recognized in doc comments" {
    const source =
        \\/// zlint-disable-next-line
        \\const a = undefined;
        \\const S = struct {
        \\    /// zlint-disable-line
        \\    x: u32 = undefined,
        \\};
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(0, s.lines.len);
    try t.expectEqual(0, s.global.count());
}

test "line directives do not disable rules globally" {
    const source =
        \\// zlint-disable-next-line
        \\const a = undefined;
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(0, s.global.count());
    try t.expectEqual(1, s.lines.len);
}

test "many lines" {
    // every other line is disabled
    const n = 64;
    const source = comptime repeat("// zlint-disable-next-line\nconst x = 1;\n", n);
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(n, s.lines.len);
    var offset: u32 = 0;
    for (0..n) |_| {
        try t.expect(!s.isSuppressed(unsafe_undefined, offset));
        offset = @intCast(std.mem.indexOfScalarPos(u8, source, offset, '\n').? + 1);
        try t.expect(s.isSuppressed(unsafe_undefined, offset));
        offset = @intCast(std.mem.indexOfScalarPos(u8, source, offset, '\n').? + 1);
    }
}

test "directive text inside string literals is ignored" {
    const source =
        \\const s = "// zlint-disable";
        \\const a = "// zlint-disable-line";
        \\const b =
        \\    \\// zlint-disable-next-line
        \\;
        \\const c = 1;
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(0, s.global.count());
    try t.expectEqual(0, s.lines.len);
}

test "stacked next-line directives each target only the following line" {
    const source =
        \\// zlint-disable-next-line unsafe-undefined
        \\// zlint-disable-next-line unused-decls
        \\const a = undefined;
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    const second = at(source, "// zlint-disable-next-line unused");
    try t.expect(s.isSuppressed(unsafe_undefined, second));
    try t.expect(!s.isSuppressed(unused_decls, second));
    const a = at(source, "const a");
    try t.expect(s.isSuppressed(unused_decls, a));
    try t.expect(!s.isSuppressed(unsafe_undefined, a));
}

test "suppressed ranges end exactly at line boundaries" {
    const source = "const a = 1;\nconst b = 1; // zlint-disable-line\nconst c = 1;";
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    const b = at(source, "const b");
    const b_newline = at(source, "\nconst c");
    try t.expect(!s.isSuppressed(unsafe_undefined, b - 1)); // newline ending line 1
    try t.expect(s.isSuppressed(unsafe_undefined, b));
    try t.expect(s.isSuppressed(unsafe_undefined, b_newline));
    try t.expect(!s.isSuppressed(unsafe_undefined, b_newline + 1));
    try t.expect(!s.isSuppressed(unsafe_undefined, @intCast(source.len)));
}

test "next-line directives may target blank lines" {
    const source = "// zlint-disable-next-line\n\nconst a = undefined;";
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    const blank = at(source, "\n\n") + 1;
    try t.expect(s.isSuppressed(unsafe_undefined, blank));
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const a")));
}

test "same-line directives on comment-only lines" {
    const source = "  // zlint-disable-line\nconst a = undefined;";
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expect(s.isSuppressed(unsafe_undefined, 0));
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const a")));
}

test "global directives in files without code" {
    inline for (.{
        .{ "", 0 },
        .{ "// zlint-disable unused-decls", 1 },
        .{ "// zlint-disable unused-decls\n", 1 },
        .{ "//! zlint-disable unused-decls\n// zlint-disable unsafe-undefined\n", 2 },
    }) |case| {
        const source, const expected = case;
        var f: Fixture = try .init(source);
        defer f.deinit();
        try t.expectEqual(expected, f.s.global.count());
        try t.expectEqual(0, f.s.lines.len);
    }
}

test "global directives must come before the first token" {
    const source =
        \\//! module docs
        \\
        \\    // zlint-disable unused-decls
        \\const a = 1;
        \\/// zlint-disable unsafe-undefined
        \\const b = 1;
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(1, s.global.count());
    try t.expect(s.global.isSet(unused_decls.int()));
}

test "directive keywords are case-insensitive but rule names are not" {
    const source =
        \\// ZLINT-DISABLE-NEXT-LINE unsafe-undefined
        \\const a = undefined;
        \\// zlint-disable-next-line Unsafe-Undefined
        \\const b = undefined;
    ;
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    try t.expectEqual(1, s.lines.len);
    try t.expect(s.isSuppressed(unsafe_undefined, at(source, "const a")));
    try t.expect(!s.isSuppressed(unsafe_undefined, at(source, "const b")));
}

test "a line directive without a rule list disables every rule" {
    const source = "const a = 1; // zlint-disable-line -- all of them";
    var f: Fixture = try .init(source);
    defer f.deinit();
    const s = &f.s;

    for (0..Suppressions.RuleMask.bit_length) |i| {
        try t.expect(s.isSuppressed(.from(@as(u32, @intCast(i))), 0));
    }
}

test "randomized sources match a per-line reference" {
    const RuleMask = Suppressions.RuleMask;
    const homeless_try = Rule.getIdFor("homeless-try").?;
    const ids = [_]Rule.Id{ unsafe_undefined, unused_decls, homeless_try };
    const lists = [_][]const u8{ "", " unsafe-undefined", " unused-decls", " unsafe-undefined, unused-decls", " not-a-rule", " -- why" };

    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    // Rules disabled on each line, indexed by line number.
    var masks: std.ArrayList(RuleMask) = .empty;
    defer masks.deinit(t.allocator);

    for (0..200) |_| {
        buf.clearRetainingCapacity();
        masks.clearRetainingCapacity();
        const newline: []const u8 = if (rand.boolean()) "\n" else "\r\n";
        const n_lines = rand.intRangeAtMost(usize, 1, 40);
        try masks.appendNTimes(t.allocator, .empty, n_lines + 1);

        for (0..n_lines) |i| {
            if (i > 0) try buf.appendSlice(t.allocator, newline);
            const list = lists[rand.uintLessThan(usize, lists.len)];
            const mask = listMask(list);
            switch (rand.uintLessThan(u8, 5)) {
                0 => try buf.print(t.allocator, "const v{d} = 1;", .{i}),
                1 => {
                    try buf.print(t.allocator, "const v{d} = 1; // zlint-disable-line{s}", .{ i, list });
                    masks.items[i].setUnion(mask);
                },
                2 => {
                    try buf.print(t.allocator, "    // zlint-disable-next-line{s}", .{list});
                    masks.items[i + 1].setUnion(mask);
                },
                3 => {},
                else => try buf.appendSlice(t.allocator, "// unrelated"),
            }
        }
        const trailing_newline = rand.boolean();
        if (trailing_newline) try buf.appendSlice(t.allocator, newline);

        const source = try t.allocator.dupeSentinel(u8, buf.items, 0);
        defer t.allocator.free(source);
        var f: Fixture = try .init(source);
        defer f.deinit();

        var line: usize = 0;
        for (0..source.len + 1) |offset| {
            // With a trailing newline, a next-line directive on the last line
            // targets the empty line after it.
            const expected = masks.items[line];
            for (ids) |id| {
                t.expectEqual(expected.isSet(id.int()), f.s.isSuppressed(id, @intCast(offset))) catch |err| {
                    std.debug.print("\nrule {d}, offset {d}, line {d}, source:\n{s}\n", .{ id.int(), offset, line, source });
                    return err;
                };
            }
            if (offset < source.len and source[offset] == '\n') line += 1;
        }
        try t.expectEqual(if (trailing_newline) n_lines else n_lines - 1, line);
    }
}

fn listMask(list: []const u8) Suppressions.RuleMask {
    var mask: Suppressions.RuleMask = .empty;
    const names = std.mem.trim(u8, list, " ");
    if (names.len == 0 or std.mem.startsWith(u8, names, "--")) return .full;
    if (std.mem.indexOf(u8, names, "unsafe-undefined") != null) mask.set(unsafe_undefined.int());
    if (std.mem.indexOf(u8, names, "unused-decls") != null) mask.set(unused_decls.int());
    return mask;
}
