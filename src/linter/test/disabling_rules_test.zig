const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

const lint = @import("../../lint.zig");
const Linter = lint.Linter;
const Config = lint.Config;
const Semantic = @import("../../Semantic.zig");

const Source = @import("../../source.zig").Source;

const ErrorList = Linter.Diagnostic.List;

const t = std.testing;
const expectEqual = t.expectEqual;

const source =
    \\const Unused = struct{
    \\  uninitialized: u32 = undefined,
    \\};
;

const both_rules = Config{
    .rules = .{ .rules = .{
        .unsafe_undefined = .{ .severity = .err },
        .unused_decls = .{ .severity = .err },
    } },
};

/// Caller owns the returned diagnostics. Free them with `freeErrors`.
fn lintSource(source_text: []const u8, config: Config) !?ErrorList {
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var src = try Source.fromString(
        t.allocator,
        try t.allocator.dupeSentinel(u8, source_text, 0),
        try t.allocator.dupe(u8, "test.zig"),
    );
    defer src.deinit();

    var builder = Semantic.Builder.init(t.allocator);
    builder.withSource(&src);
    defer builder.deinit();
    var res = try builder.build(src.text());
    defer res.deinit();

    var linter = try Linter.init(t.allocator, .{ .arena = &arena, .config = config });
    defer linter.deinit();

    var errors: ?ErrorList = null;
    linter.runOnSource(std.testing.io, &res.value, &src, &errors) catch |e| switch (e) {
        error.LintingFailed => {},
        else => return e,
    };
    return errors;
}

/// Multiline string literals can't contain `\r`.
fn crlf(comptime lf: []const u8) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (lf) |c| out = out ++ if (c == '\n') "\r\n" else .{c};
        break :blk out;
    };
}

fn freeErrors(errors: ?ErrorList) void {
    const errs = errors orelse return;
    for (errs.items) |*err| err.deinit(t.allocator);
    errs.deinit();
}

fn expectCodes(expected: []const []const u8, errors: ?ErrorList) !void {
    const errs = errors orelse return expectEqual(0, expected.len);
    try expectEqual(expected.len, errs.items.len);
    for (expected, errs.items) |code, err| try t.expectEqualStrings(code, err.err.code);
}

test "Enabled rules have their violations reported" {
    const errors = try lintSource(source, both_rules);
    defer freeErrors(errors);
    try expectEqual(2, errors.?.items.len);
}

test "When no rules are enabled, no violations are reported" {
    const errors = try lintSource(source, .empty);
    defer freeErrors(errors);
    try expectEqual(null, errors);
}

test "When a rule is configured to 'off', none of its violations are reported" {
    const errors = try lintSource(source, .{
        .rules = .{ .rules = .{ .unsafe_undefined = .{ .severity = .err } } },
    });
    defer freeErrors(errors);
    try expectCodes(&.{"unsafe-undefined"}, errors);
}

test "When rules are configured but a specific rule is disabled with 'zlint-disable', only non-disabled rules get reported" {
    const errors = try lintSource(
        \\// zlint-disable unsafe-undefined
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectCodes(&.{"unused-decls"}, errors);
}

test "When rules are configured but disabled with 'zlint-disable', nothing gets reported" {
    const errors = try lintSource(
        \\// zlint-disable
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectEqual(null, errors);
}

test "When the global disable directive is misplaced, violations still gets reported" {
    const errors = try lintSource(
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
        \\// zlint-disable
    , both_rules);
    defer freeErrors(errors);
    try expectEqual(2, errors.?.items.len);
}

test "When the multiple global directives are set, all rules are honored" {
    const errors = try lintSource(
        \\// zlint-disable unused-decls unsafe-undefined
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectEqual(null, errors);
}

test "Separate global directives are all honored" {
    const errors = try lintSource(
        \\// zlint-disable unused-decls
        \\// zlint-disable unsafe-undefined
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectEqual(null, errors);
}

test "zlint-disable-next-line suppresses violations on the next line" {
    const errors = try lintSource(
        \\const Unused = struct{
        \\  // zlint-disable-next-line unsafe-undefined
        \\  uninitialized: u32 = undefined,
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectCodes(&.{"unused-decls"}, errors);
}

test "zlint-disable-line suppresses violations on the same line" {
    const errors = try lintSource(
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined, // zlint-disable-line -- trust me
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectCodes(&.{"unused-decls"}, errors);
}

test "Line directives only suppress the rules they name" {
    const errors = try lintSource(
        \\// zlint-disable-next-line unsafe-undefined
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined, // zlint-disable-line unused-decls
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectEqual(2, errors.?.items.len);
}

test "Line directives do not suppress violations on other lines" {
    const errors = try lintSource(
        \\// zlint-disable-next-line
        \\
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
        \\// zlint-disable-line
    , both_rules);
    defer freeErrors(errors);
    try expectEqual(2, errors.?.items.len);
}

test "Line directives in doc comments are ignored" {
    const errors = try lintSource(
        \\const Unused = struct{
        \\  /// zlint-disable-next-line
        \\  uninitialized: u32 = undefined,
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectEqual(2, errors.?.items.len);
}

test "Line directives target the reported line of multi-label violations" {
    const duplicate_case = Config{ .rules = .{ .rules = .{ .duplicate_case = .{ .severity = .err } } } };
    const on_duplicate = try lintSource(
        \\fn f(x: u32) u32 {
        \\    return switch (x) {
        \\        1 => 1,
        \\        // zlint-disable-next-line duplicate-case
        \\        1 => 1,
        \\        else => 0,
        \\    };
        \\}
    , duplicate_case);
    defer freeErrors(on_duplicate);
    try expectCodes(&.{}, on_duplicate);

    const on_original = try lintSource(
        \\fn f(x: u32) u32 {
        \\    return switch (x) {
        \\        1 => 1, // zlint-disable-line duplicate-case
        \\        1 => 1,
        \\        else => 0,
        \\    };
        \\}
    , duplicate_case);
    defer freeErrors(on_original);
    try expectCodes(&.{"duplicate-case"}, on_original);
}

test "Global and line directives combine" {
    const errors = try lintSource(
        \\// zlint-disable unused-decls
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined, // zlint-disable-line unsafe-undefined
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectEqual(null, errors);
}

test "Line directives work with CRLF line endings" {
    const source_crlf = crlf(
        \\const Unused = struct{
        \\  // zlint-disable-next-line unsafe-undefined
        \\  uninitialized: u32 = undefined,
        \\};
        \\
    );
    try expectEqual(4, std.mem.count(u8, source_crlf, "\r\n"));
    const errors = try lintSource(source_crlf, both_rules);
    defer freeErrors(errors);
    try expectCodes(&.{"unused-decls"}, errors);
}

test "Line directives with unknown or misspelled rule names suppress nothing" {
    const errors = try lintSource(
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined, // zlint-disable-line unsafe-undefine, Unsafe-Undefined
        \\};
    , both_rules);
    defer freeErrors(errors);
    try expectEqual(2, errors.?.items.len);
}

test "Directive text inside strings does not suppress violations" {
    const errors = try lintSource(
        \\const Unused = "// zlint-disable-line";
    , both_rules);
    defer freeErrors(errors);
    try expectCodes(&.{"unused-decls"}, errors);
}
