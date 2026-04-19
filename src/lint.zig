pub const Linter = @import("linter/linter.zig").Linter;
pub const LintService = @import("linter/LintService.zig");
pub const Config = @import("linter/Config.zig");
pub const Rule = @import("linter/rule.zig").Rule;
pub const rules = @import("linter/rules.zig");
pub const Fix = @import("linter/fix.zig").Fix;

test {
    const std = @import("std");

    // Ensure intellisense. Especially important when authoring a new rule.
    std.testing.refAllDecls(@This());
    std.testing.refAllDeclsRecursive(@import("linter/rules.zig"));

    // Test suites
    std.testing.refAllDecls(@import("linter/test/disabling_rules_test.zig"));
    std.testing.refAllDecls(@import("linter/test/fix_test.zig"));
}
