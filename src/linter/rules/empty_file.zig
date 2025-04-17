//! ## What This Rule Does
//! This rule checks for empty .zig files in the project.
//! A file should be deemed empty if it has no content (zero bytes) or only comments and whitespace characters,
//! as defined by the standard library in [`std.ascii.whitespace`](https://ziglang.org/documentation/master/std/#std.ascii.whitespace).
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//!
//!
//! ```zig
//! // an "empty" file is actually a file without meaningful code: just comments (doc or normal) or whitespace
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn exampleFunction() void {
//! }
//! ```

const std = @import("std");
const _rule = @import("../rule.zig");
const util = @import("util");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;

const Error = @import("../../Error.zig");

// Rule metadata
const EmptyFile = @This();
pub const meta: Rule.Meta = .{
    .name = "empty-file",
    .category = .style,
    .default = .warning,
};

pub fn fileDiagnosticWithMessage(ctx: *LinterContext, msg: []const u8) Error {
    const filename = ctx.source.pathname orelse "anonymous source file";
    return ctx.diagnosticf("{s} {s}", .{ filename, msg }, .{});
}

// Runs once per source file. Useful for unique checks
pub fn runOnce(_: *const EmptyFile, ctx: *LinterContext) void {
    const source = ctx.source.text();
    var message: ?[]const u8 = null;
    if (source.len == 0) {
        message = "has zero bytes";
    } else if (std.mem.indexOfNone(u8, source, &std.ascii.whitespace) == null) {
        message = "contains only whitespace";
    } else if (ctx.ast().nodes.len == 1) {
        message = "only contains comments";
    }
    if (message) |msg| {
        ctx.report(fileDiagnosticWithMessage(ctx, msg));
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
        ,
        \\// anything that is not a comment or whitespace will turn
        \\// this into a non-empty file
        \\var x = 0;
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
        ,
        // tabs
        \\             
        ,
        \\// only a comment
        ,
        \\//! only a doc comment
        ,
        \\//! a doc comment
        \\// but with a normal comment just below!
        ,
        \\// only a comment with some whitespace
        \\                       
        \\
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
