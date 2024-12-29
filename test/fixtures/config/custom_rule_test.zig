const std = @import("std");

// const Rule = @import("./linter/rule.zig").Rule;
// const NodeWrapper = @import("./linter/rule.zig").NodeWrapper;
// const Symbol = @import("./semantic/Symbol.zig");
// const LinterContext = @import("./linter/lint_context.zig").Context;

const Rule = @import("zlint").Rule;
const NodeWrapper = @import("zlint").NodeWrapper;
const Symbol = @import("zlint").Symbol;
const LinterContext = @import("zlint").LinterContext;

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
