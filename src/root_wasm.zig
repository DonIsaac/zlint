const std = @import("std");

pub const semantic = @import("semantic.zig");
pub const Source = @import("source.zig").Source;
pub const report = @import("reporter.zig");

pub const lint = @import("lint.zig");

/// Internal. Exported for codegen.
pub const json = @import("json.zig");

export fn analyze(source: []const u8) void {
    @panic("todo");
}
