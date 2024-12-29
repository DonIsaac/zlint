const std = @import("std");

const Rule = @import("zlint").Rule;
const NodeWrapper = @import("zlint").NodeWrapper;
const Symbol = @import("zlint").Symbol;
const LinterContext = @import("zlint").LinterContext;

const user_rule = @import("user_entry");

// FIXME: the runtime compiler invocation will have its own entry zig file which imports all the above
// stuff and implements this C API for you. It will also handle providing some `zlint` import
export fn _zlint_meta() *const Rule.Meta {
    return &user_rule.meta;
}

export fn _zlint_runOnNode(self: *const anyopaque, node: NodeWrapper, ctx: *LinterContext) u16 {
    user_rule.runOnNode(self, node, ctx) catch |err| {
        return @intFromError(err);
    };

    return 0;
}

export fn _zlint_runOnSymbol(self: *const anyopaque, sym: Symbol.Id, ctx: *LinterContext) u16 {
    user_rule.runOnSymbol(self, sym, ctx) catch |err| {
        return @intFromError(err);
    };

    return 0;
}
