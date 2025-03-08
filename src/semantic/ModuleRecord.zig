const ModuleRecord = @This();

imports: std.ArrayListUnmanaged(ImportEntry) = .{},

pub fn deinit(self: *ModuleRecord, allocator: Allocator) void {
    self.imports.deinit(allocator);
    self.* = undefined;
}

/// An import to a module or file.
///
/// Does not include `@cImport`s (for now, this may change).
///
/// ### Example
///```zig
/// @import("some_module") // kind: module
/// //       ^^^^^^^^^^^ specifier
/// ```
pub const ImportEntry = struct {
    specifier: []const u8,
    /// The `@import` node
    node: NodeIndex,
    kind: Kind,

    pub const Kind = enum {
        /// An import to a named module, such as `std`, `builtin`, or some dependency.
        ///
        /// Non-intrinsic modules are set in `build.zid`.
        module,
        /// An import to a `.zig` or `.zon` file.
        ///
        /// Specifier is a relative path to the file.
        file,
    };
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const NodeIndex = @import("ast.zig").NodeIndex;
