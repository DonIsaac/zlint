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
    //std.debug.print("{*},{any},{*}", .{ self, node, ctx });
    _ = self;
    _ = node;
    _ = ctx;
}

pub fn runOnSymbol(self: *const anyopaque, sym: Symbol.Id, ctx: *LinterContext) !void {
    _ = self;
    const s = sym.into(usize);
    const slice = ctx.symbols().symbols.slice();
    const flags: Symbol.Flags = slice.items(.flags)[s];
    if (!(flags.s_variable and flags.s_const))
        return;

    const name = slice.items(.name)[s];

    const e = ctx.diagnosticFmt(
        "hello from user defined rule! symbol: '{s}'",
        .{name},
        .{ctx.spanT(slice.items(.token)[s].unwrap().?.int())},
    );

    e.help = .{
        .str = "how fun",
        .static = true,
    };
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
