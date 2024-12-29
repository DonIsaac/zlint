const std = @import("std");

const Rule = @import("./linter/rule.zig").Rule;
const NodeWrapper = @import("./linter/rule.zig").NodeWrapper;
const Symbol = @import("./semantic/Symbol.zig");
const LinterContext = @import("./linter/lint_context.zig").Context;

pub const meta: Rule.Meta = .{
    .name = "string",
    .category = .suspicious,
    .default = .err,
};

pub fn runOnNode(self: *const anyopaque, node: NodeWrapper, ctx: *LinterContext) !void {
    std.debug.print("{*},{any},{*}", .{ self, node, ctx });
}

pub fn runOnSymbol(self: *const anyopaque, sym: Symbol.Id, ctx: *LinterContext) !void {
    std.debug.print("{*},{},{*}", .{ self, sym, ctx });
}

// FIXME: the runtime compiler invocation will have its own entry zig file which imports all the above
// stuff and implements this C API for you. It will also handle providing some `zlint` import
export fn _zlint_meta() *const Rule.Meta {
    return &meta;
}

export fn _zlint_runOnNode(self: *const anyopaque, node: NodeWrapper, ctx: *LinterContext) u16 {
    runOnNode(self, node, ctx) catch |err| {
        return @intFromError(err);
    };

    return 0;
}

export fn _zlint_runOnSymbol(self: *const anyopaque, sym: Symbol.Id, ctx: *LinterContext) u16 {
    runOnSymbol(self, sym, ctx) catch |err| {
        return @intFromError(err);
    };

    return 0;
}
