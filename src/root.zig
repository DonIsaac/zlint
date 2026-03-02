const std = @import("std");

pub const zig = @import("zig.zig").current;
pub const Semantic = @import("Semantic.zig");
pub const Source = @import("source.zig").Source;

pub const report = @import("reporter.zig");

pub const lint = @import("lint.zig");

/// Internal. Exported for codegen.
pub const json = @import("json.zig");

pub const printer = struct {
    pub const Printer = @import("printer/Printer.zig");
    pub const SemanticPrinter = @import("printer/SemanticPrinter.zig");
    pub const AstPrinter = @import("printer/AstPrinter.zig");
};

pub const walk = @import("visit/walk.zig");

pub const cli = struct {
    pub const LintConfig = @import("cli/lint_config.zig");
    pub const Options = @import("cli/Options.zig");
    // TODO: Uncomment when cli/test/print_ast_test.zig is fixed.
    //pub const PrintCommand = @import("cli/print_command.zig");
};

test {
    std.testing.refAllDecls(@import("util"));
    std.testing.refAllDeclsRecursive(printer);
    std.testing.refAllDeclsRecursive(zig);
    std.testing.refAllDeclsRecursive(json);
    std.testing.refAllDeclsRecursive(cli);
}
