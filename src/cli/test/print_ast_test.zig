const std = @import("std");
const Source = @import("../../source.zig").Source;

// const allocator = std.testing.allocator;
const print_command = @import("../print_command.zig");

const source_code: [:0]const u8 =
    \\pub const Foo = struct {
    \\    a: u32,
    \\    b: bool,
    \\    c: ?[]const u8,
    \\};
    \\const x: Foo = Foo{ .a = 1, .b = true, .c = "hello" };
;

test print_command {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source = try Source.fromString(allocator, @constCast(source_code), "foo.zig");
    var buf = try std.ArrayList(u8).initCapacity(allocator, source.text().len);
    const writer = buf.writer();

    try print_command.parseAndPrint(allocator, .{ .verbose = true }, source, writer.any());
    // fixme: lots of trailing commas
    // const parsed = try std.json.parseFromSliceLeaky(json.Value, allocator, buf.items, .{});
    // try std.testing.expect(parsed == .object);
}
