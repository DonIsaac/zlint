const std = @import("std");
const meta = std.meta;
const test_util = @import("util.zig");

const Symbol = @import("../Symbol.zig");
const Reference = @import("../Reference.zig");

const t = std.testing;
const panic = std.debug.panic;
const print = std.debug.print;
const build = test_util.build;

test "container exports" {
    const TestCase = struct {
        src: [:0]const u8,
        container_id: Symbol.Id,
        exports: []const []const u8,
        fn init(src: [:0]const u8, container_id: Symbol.Id.Repr, exports: anytype) @This() {
            return .{ .src = src, .container_id = Symbol.Id.from(container_id), .exports = exports };
        }
    };

    const test_cases = [_]TestCase{
        .init(
            "const foo = 1;",
            0,
            &[_][]const u8{"foo"},
        ),
        .init(
            \\const Foo = struct {
            \\    a: u32,
            \\    b: u32,
            \\    const C = 1;
            \\    pub const D = struct {};
            \\    fn e() void {}
            \\};
        ,
            1,
            &[_][]const u8{ "C", "D", "e" },
        ),
    };

    for (test_cases) |tc| {
        var semantic = try build(tc.src);
        defer semantic.deinit();
        const container = semantic.symbols.get(tc.container_id);
        t.expectEqual(tc.exports.len, container.exports.items.len) catch |e| {
            print("\nexports: ", .{});
            for (container.exports.items) |symbol_id| {
                const symbol = semantic.symbols.get(symbol_id);
                print("'{s}', ", .{symbol.name});
            }
            print("\n", .{});
            return e;
        };
        for (tc.exports) |expected_export| {
            var found = false;
            for (container.exports.items) |symbol_id| {
                const symbol = semantic.symbols.get(symbol_id);
                if (std.mem.eql(u8, symbol.name, expected_export)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                print("expected export {s} not found\nexports: ", .{expected_export});
                for (container.exports.items) |symbol_id| {
                    const symbol = semantic.symbols.get(symbol_id);
                    print("'{s}'', ", .{symbol.name});
                }
                print("\n", .{});
                return error.ZigTestFailed;
            }
        }
    }
}
