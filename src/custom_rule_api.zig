const std = @import("std");

pub const Severity = @import("./Error.zig").Severity;
pub const Category = @import("./linter/rule.zig").Rule.Category;
pub const Meta = @import("./linter/rule.zig").Rule.Meta;

// FIXME:
pub const NodeWrapper = extern struct {
    node: *const std.zig.Ast.Node,
    idx: std.zig.Ast.Node.Index,

    pub inline fn getMainTokenOffset(self: *const NodeWrapper, ast: *const std.zig.Ast) u32 {
        const starts = ast.tokens.items(.start);
        return starts[self.node.main_token];
    }
};

pub const Symbol = @import("./semantic/Symbol.zig");
pub const LinterContext = @import("./linter/lint_context.zig").Context;
