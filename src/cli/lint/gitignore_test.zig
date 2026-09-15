const std = @import("std");
const lint = @import("zlint").lint;
const gitignore = @import("gitignore.zig");

const Dir = std.Io.Dir;
const ArenaAllocator = std.heap.ArenaAllocator;
const t = std.testing;

test "readGitignore does not fall back to cwd for a discovered config" {
    const cwd = Dir.cwd();

    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const config_path = try cwd.realPathFileAlloc(t.io, "test/fixtures/config/zlint.json", arena.allocator());
    // start with no patterns so anything present afterwards came from a `.gitignore`
    const base: lint.Config = .{ .ignore = .empty };
    var config = base.intoManaged(&arena, config_path);

    try gitignore.readGitignore(&config, t.io, cwd, .beside_config);
    try t.expectEqual(0, config.config.ignore.patterns.len);
}
