const std = @import("std");

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

test {
    std.testing.refAllDecls(@import("util"));
    std.testing.refAllDecls(printer);
    std.testing.refAllDecls(json);
    std.testing.refAllDecls(lint);
    std.testing.refAllDecls(walk);

    // `src/cli/` isn't part of the public library surface, so it's only pulled
    // in here to get its tests compiled and run.
    std.testing.refAllDecls(@import("cli/Options.zig"));
    std.testing.refAllDecls(@import("cli/lint_command.zig"));
    std.testing.refAllDecls(@import("cli/lint_config.zig"));
    std.testing.refAllDecls(@import("cli/print_command.zig"));
}
