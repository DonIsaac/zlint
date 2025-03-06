//! ## What This Rule Does
//! Explain what this rule checks for. Also explain why this is a problem.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn exampleFunction() void {
//! }
//! ```

const std = @import("std");
const _rule = @import("../rule.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;

const Error = @import("../../Error.zig");

// Rule metadata
const EmptyFile = @This();
pub const meta: Rule.Meta = .{
    .name = "empty-file",
    .category = .style,
};

pub fn emptyFileDiagnostic(ctx: *LinterContext) Error {
    const filename = ctx.source.pathname orelse "anonymous source file";
    return ctx.diagnosticf(
        "{s} is completely empty",
        .{filename},
        .{},
    );
}

pub fn whitespaceFileDiagnostic(ctx: *LinterContext) Error {
    const filename = ctx.source.pathname orelse "anonymous source file";
    return ctx.diagnosticf(
        "{s} only contains whitespace",
        .{filename},
        .{},
    );
}

// Runs once per source file. Useful for unique checks
pub fn runOnce(_: *const EmptyFile, ctx: *LinterContext) void {
    const source = ctx.source.text();
    if (source.len == 0) {
        ctx.report(emptyFileDiagnostic(ctx));
        return;
    }
    if (std.mem.indexOfNone(u8, source, &std.ascii.whitespace) == null) {
        ctx.report(whitespaceFileDiagnostic(ctx));
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *EmptyFile) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test EmptyFile {
    const t = std.testing;

    var empty_file = EmptyFile{};
    var runner = RuleTester.init(t.allocator, empty_file.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        \\// non-empty file
        \\fn exampleFunction() void {
        \\}
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // no content
        "",
        // newlines
        \\
        \\
        \\
        ,
        // space
        \\    
        // tabs
        \\             
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
