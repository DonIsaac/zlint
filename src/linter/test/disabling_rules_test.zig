const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Linter = @import("../../linter.zig").Linter;
const Config = @import("../../linter.zig").Config;
const Source = @import("../../source.zig").Source;
const Error = @import("../../Error.zig");
const ErrorList = std.ArrayList(Error);

const t = std.testing;
const expectEqual = t.expectEqual;

const source =
    \\const Unused = struct{
    \\  uninitialized: u32 = undefined,
    \\};
;
fn makeSource(arena: Allocator, source_text: []const u8) !Source {
    const srctext = try arena.dupeZ(u8, source_text);
    errdefer arena.free(srctext);

    const path = try arena.dupe(u8, "test.zig");
    errdefer arena.free(path);

    return Source.fromString(arena, srctext, path);
}

test "Enabled rules have their violations reported" {
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var src = try makeSource(t.allocator, source);
    defer src.deinit();

    var errors: ?ErrorList = null;
    defer if (errors) |errs| {
        for (errs.items) |*err| err.deinit(t.allocator);
        errs.deinit();
    };

    const config = Config{
        .rules = .{
            .unsafe_undefined = .{ .severity = .err },
            .unused_decls = .{ .severity = .err },
        },
    };

    {
        var linter = try Linter.init(t.allocator, .{ .arena = &arena, .config = config });
        defer linter.deinit();
        linter.runOnSource(&src, &errors) catch |e| {
            switch (e) {
                error.OutOfMemory => return e,
                else => {},
            }
        };
        try expectEqual(2, errors.?.items.len);
    }
}

test "When no rules are enabled, no violations are reported" {
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var src = try makeSource(t.allocator, source);
    defer src.deinit();

    var errors: ?ErrorList = null;
    // only populated when linting fails, which should not happen (that's what's
    // being tested).
    errdefer if (errors) |errs| {
        for (errs.items) |*err| err.deinit(t.allocator);
        errs.deinit();
    };

    {
        var linter = try Linter.init(t.allocator, .{ .arena = &arena, .config = .{} });

        defer linter.deinit();
        try linter.runOnSource(&src, &errors);
        try expectEqual(null, errors);
    }
}

test "When a rule is configured to 'off', none of its violations are reported" {
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var src = try makeSource(t.allocator, source);
    defer src.deinit();

    var errors: ?ErrorList = null;
    defer if (errors) |errs| {
        for (errs.items) |*err| err.deinit(t.allocator);
        errs.deinit();
    };

    const config = Config{
        .rules = .{
            .unsafe_undefined = .{ .severity = .err },
        },
    };

    {
        var linter = try Linter.init(t.allocator, .{ .arena = &arena, .config = config });
        defer linter.deinit();
        linter.runOnSource(&src, &errors) catch |e| {
            switch (e) {
                error.OutOfMemory => return e,
                else => {},
            }
        };
        try expectEqual(1, errors.?.items.len);
        try expectEqual("unsafe-undefined", errors.?.items[0].code);
    }
}

test "When rules are configured but a specific rule is disabled with 'zlint-disable', only non-disabled rules get reported" {
    const source_with_global_disable =
        \\// zlint-disable unsafe-undefined
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
    ;
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var src = try makeSource(t.allocator, source_with_global_disable);
    defer src.deinit();

    var errors: ?ErrorList = null;
    defer if (errors) |errs| {
        for (errs.items) |*err| err.deinit(t.allocator);
        errs.deinit();
    };

    const config = Config{
        .rules = .{
            .unsafe_undefined = .{ .severity = .err },
            .unused_decls = .{ .severity = .err },
        },
    };

    {
        var linter = try Linter.init(t.allocator, .{ .arena = &arena, .config = config });
        defer linter.deinit();
        linter.runOnSource(&src, &errors) catch |e| {
            switch (e) {
                error.OutOfMemory => return e,
                else => {},
            }
        };
        try expectEqual(1, errors.?.items.len);
        try expectEqual("unused-decls", errors.?.items[0].code);
    }
}

test "When rules are configured but disabled with 'zlint-disable', nothing gets reported" {
    const source_with_global_disable =
        \\// zlint-disable
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
    ;
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var src = try makeSource(t.allocator, source_with_global_disable);
    defer src.deinit();

    var errors: ?ErrorList = null;
    defer if (errors) |errs| {
        for (errs.items) |*err| err.deinit(t.allocator);
        errs.deinit();
    };

    const config = Config{
        .rules = .{
            .unsafe_undefined = .{ .severity = .err },
            .unused_decls = .{ .severity = .err },
        },
    };

    {
        var linter = try Linter.init(t.allocator, .{ .arena = &arena, .config = config });
        defer linter.deinit();
        linter.runOnSource(&src, &errors) catch |e| {
            switch (e) {
                error.OutOfMemory => return e,
                else => {},
            }
        };
        try expectEqual(null, errors);
    }
}

test "When the global disable directive is misplaced, violations still gets reported" {
    const source_with_global_disable =
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
        \\// zlint-disable
    ;
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var src = try makeSource(t.allocator, source_with_global_disable);
    defer src.deinit();

    var errors: ?ErrorList = null;
    defer if (errors) |errs| {
        for (errs.items) |*err| err.deinit(t.allocator);
        errs.deinit();
    };

    const config = Config{
        .rules = .{
            .unsafe_undefined = .{ .severity = .err },
            .unused_decls = .{ .severity = .err },
        },
    };

    {
        var linter = try Linter.init(t.allocator, .{ .arena = &arena, .config = config });
        defer linter.deinit();
        linter.runOnSource(&src, &errors) catch |e| {
            switch (e) {
                error.OutOfMemory => return e,
                else => {},
            }
        };
        try expectEqual(2, errors.?.items.len);
    }
}

test "When the multiple global directives are set, all rules are honored" {
    const source_with_global_disable =
        \\// zlint-disable unused-decls unsafe-undefined
        \\const Unused = struct{
        \\  uninitialized: u32 = undefined,
        \\};
    ;
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var src = try makeSource(t.allocator, source_with_global_disable);
    defer src.deinit();

    var errors: ?ErrorList = null;
    defer if (errors) |errs| {
        for (errs.items) |*err| err.deinit(t.allocator);
        errs.deinit();
    };

    const config = Config{
        .rules = .{
            .unsafe_undefined = .{ .severity = .err },
            .unused_decls = .{ .severity = .err },
        },
    };

    {
        var linter = try Linter.init(t.allocator, .{ .arena = &arena, .config = config });
        defer linter.deinit();

        linter.runOnSource(&src, &errors) catch |e| {
            switch (e) {
                error.OutOfMemory => return e,
                else => {},
            }
        };
        try expectEqual(null, errors);
    }
}
