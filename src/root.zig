const std = @import("std");

pub const semantic = @import("semantic.zig");
pub const Source = @import("source.zig").Source;

pub const report = @import("reporter.zig");

pub const lint = struct {
    pub const Linter = @import("linter.zig").Linter;
    pub const Rule = @import("linter/rule.zig").Rule;
    pub const rules = @import("linter/rules.zig");
};

pub const printer = struct {
    pub const Printer = @import("printer/Printer.zig");
    pub const SemanticPrinter = @import("printer/SemanticPrinter.zig");
    pub const AstPrinter = @import("printer/AstPrinter.zig");
};

pub const walk = @import("visit/walk.zig");

test {
    std.testing.refAllDecls(@import("util"));
}
