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

const builtin = @import("builtin");
const std = @import("std");
const util = @import("util");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const span = @import("../../span.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Scope = semantic.Scope;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const Line = span.Line;
const NodeWrapper = _rule.NodeWrapper;
const Symbol = semantic.Symbol;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);
const LabeledSpan = span.LabeledSpan;

const Self = @This();
pub const meta: Rule.Meta = .{
    .name = "line-length",
    .category = .style,
    .default = .off,
};

pub fn lineLengthDiagnostic(ctx: *LinterContext, line_start: u32, threshold: u32, line_length: u32) Error {
    return ctx.diagnosticf(
        "line length of {} characters is too big.",
        .{line_length},
        .{LabeledSpan.unlabeled(line_start + threshold, line_start + line_length)},
    );
}

pub const LineLength = struct {
    max_length: u32 = 120,
};
pub var config: LineLength = LineLength{};

pub fn getLineLength() u32 {
    return config.max_length;
}

pub fn runOnce(_: *const Self, ctx: *LinterContext) void {
    var line_start_idx: u32 = 0;
    var lines = std.mem.splitSequence(u8, ctx.source.text(), util.NEWLINE);
    var i: u32 = 1;
    const threshold: u32 = getLineLength();
    while (lines.next()) |line| : (i += 1) {
        const line_length = @as(u32, @intCast(line.len));
        if (line.len > threshold) {
            ctx.report(lineLengthDiagnostic(ctx, line_start_idx, threshold, line_length));
        }
        line_start_idx += line_length + @as(u32, @intCast(util.NEWLINE.len));
    }
}

pub fn rule(self: *Self) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test Self {
    const t = std.testing;

    var line_length = Self{};
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
