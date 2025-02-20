//! ## What This Rule Does
//!
//! Checks if any line goes beyond a given number of columns.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule (with a threshold of 120 columns):
//! ```zig
//! const std = @import("std");
//! const longStructDeclarationInOneLine = struct { max_length: u32 = 120, a: usize = 123, b: usize = 12354, c: usize = 1234352 };
//! fn reallyExtraVerboseFunctionNameToThePointOfBeingACodeSmellAndProbablyAHintThatYouCanGetAwayWithAnotherNameOrSplittingThisIntoSeveralFunctions() u32 {
//!     return 123;
//! }
//! ```
//!
//! Examples of **correct** code for this rule (with a threshold of 120 columns):
//! ```zig
//! const std = @import("std");
//! const longStructInMultipleLines = struct {
//!     max_length: u32 = 120,
//!     a: usize = 123,
//!     b: usize = 12354,
//!     c: usize = 1234352,
//! };
//! fn Get123Constant() u32 {
//!     return 123;
//! }
//! ```

const std = @import("std");
const _rule = @import("../rule.zig");
const span = @import("../../span.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const Error = @import("../../Error.zig");
const LabeledSpan = span.LabeledSpan;

max_length: u32 = 120,

const LineLength = @This();
pub const meta: Rule.Meta = .{
    .name = "line-length",
    .category = .style,
    .default = .off,
};

pub fn lineLengthDiagnostic(ctx: *LinterContext, line_start: u32, line_length: u32) Error {
    return ctx.diagnosticf(
        "line length of {} characters is too big.",
        .{line_length},
        .{LabeledSpan.unlabeled(line_start, line_start + line_length)},
    );
}

pub fn getNewlineOffset(line: []const u8) u32 {
    if (line.len > 1 and line[line.len - 2] == '\r') {
        return 2;
    }
    return 1;
}

pub fn runOnce(self: *const LineLength, ctx: *LinterContext) void {
    var line_start_idx: u32 = 0;
    var lines = std.mem.splitSequence(u8, ctx.source.text(), "\n");
    const newline_offset = getNewlineOffset(lines.first());
    lines.reset();
    while (lines.next()) |line| {
        const line_length = @as(u32, @intCast(line.len));
        if (line.len > self.max_length) {
            ctx.report(lineLengthDiagnostic(ctx, line_start_idx, line_length));
        }
        line_start_idx += line_length + newline_offset;
    }
}

pub fn rule(self: *LineLength) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test LineLength {
    const t = std.testing;

    var line_length = LineLength{};
    var runner = RuleTester.init(t.allocator, line_length.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        \\const std = @import("std");
        \\fn foo() std.mem.Allocator.Error!void {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\const longStructInMultipleLines = struct {
        \\    max_length: u32 = 120,
        \\    a: usize = 123,
        \\    b: usize = 12354,
        \\    c: usize = 1234352,
        \\};
        \\fn Get123Constant() u32 {
        \\    return 123;
        \\}
    };

    const fail = &[_][:0]const u8{
        \\const std = @import("std");
        \\fn foo() std.mem.Allocator.Error!void {
        \\  // ok so this is a super unnecessary line that is artificially being made long through this self-referential comment thats keeps on going until hitting a number of columns that violates the rule
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\const longStructDeclarationInOneLine = struct { max_length: u32 = 120, a: usize = 123, b: usize = 12354, c: usize = 1234352 };
        \\fn reallyExtraVerboseFunctionNameToThePointOfBeingACodeSmellAndProbablyAHintThatYouCanGetAwayWithAnotherNameOrSplittingThisIntoSeveralFunctions() u32 {
        \\    return 123;
        \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
