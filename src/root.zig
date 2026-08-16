const std = @import("std");

pub const Semantic = @import("Semantic.zig");
pub const Source = @import("source.zig").Source;

pub const report = @import("reporter.zig");

pub const lint = @import("lint.zig");

pub const Error = @import("Error.zig");
pub const span = @import("span.zig");
pub const rule = @import("linter/rule.zig");
pub const ast_utils = @import("linter/ast_utils.zig");
pub const lint_context = @import("linter/lint_context.zig");

// Surface needed to author a rule out-of-tree. Custom rules are compiled as
// their own modules, so they can't reach these by relative path.
pub const linter = struct {
    pub const Error = @import("Error.zig");
    pub const span = @import("span.zig");
    pub const rule = @import("linter/rule.zig");
    pub const ast_utils = @import("linter/ast_utils.zig");
    pub const lint_context = @import("linter/lint_context.zig");
    pub const tester = @import("linter/tester.zig");
};

/// Internal. Exported for codegen.
pub const json = @import("json.zig");

pub const printer = struct {
    pub const Printer = @import("printer/Printer.zig");
    pub const SemanticPrinter = @import("printer/SemanticPrinter.zig");
    pub const AstPrinter = @import("printer/AstPrinter.zig");
};

pub const walk = @import("visit/walk.zig");

const tty = @import("io/tty.zig");

test {
    std.testing.refAllDecls(@import("util"));
    std.testing.refAllDecls(printer);
    std.testing.refAllDecls(json);
    std.testing.refAllDecls(lint);
    std.testing.refAllDecls(walk);
    std.testing.refAllDecls(tty);
}
