const RESET = "\x1b[0m";
const Style = @This();

pub const styles = @import("styles/styles.zig");
comptime {
    _ = @import("styles/Color.zig");
    _ = @import("styles/control.zig");
}
test {
    const std = @import("std");
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDecls(@import("styles/control.zig"));
}
