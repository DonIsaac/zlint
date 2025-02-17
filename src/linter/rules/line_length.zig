//! ## What This Rule Does
//!
//! Checks if any line goes beyond a given number of columns.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule (with a threshold of 120 columns):
//! ```zig
//! const std = @import("std");
//! const longStructDeclaractionInOneLine = struct { max_length: u32 = 120, a: usize = 123, b: usize = 12354, c: usize = 1234352 };
//! fn reallyExtraVerboseFunctionNameToThePointOfBeingACodeSmellAndProbablyAHintThatYouCanGetAwayWithAnotherNameOrSplittingThisIntoSeveralFunctions() u32 {
//!     return 123;
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
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
const util = @import("util");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Scope = semantic.Scope;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const Line = @import("../../reporter/formatters/GraphicalFormatter.zig").Line;
const NodeWrapper = _rule.NodeWrapper;
const Symbol = semantic.Symbol;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

const Self = @This();
pub const meta: Rule.Meta = .{
    .name = "line-length",
    .category = .style,
    .default = .off,
};

pub fn lineLengthDiagnostic(ctx: *LinterContext, line: Line) Error {
    return ctx.diagnosticf(
        "line length of {} characters is too big.",
        .{line.len()},
        .{ctx.spanL(line)},
    );
}

pub fn runOnce(_: *const Self, ctx: *LinterContext) void {
    var line_start_idx: u32 = 0;
    var lines = std.mem.tokenizeSequence(u8, ctx.source.text(), "\n");
    var i: u32 = 0;
    while (lines.next()) |line| : (i += 1) {
        if (line.len > 120) {
            const line_data = Line{
                .num = i + 1,
                .contents = line,
                .offset = line_start_idx,
            };
            ctx.report(lineLengthDiagnostic(ctx, line_data));
        }
        line_start_idx += @as(u32, @intCast(line.len));
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
        // TODO: add test cases
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
        // TODO: add test cases
        \\const std = @import("std");
        \\fn foo() std.mem.Allocator.Error!void {
        \\  // ok so this is a super unnecessary line that is artificially being made long through this self-referential comment thats keeps on going until hitting a number of columns that violates the rule
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\const longStructDeclaractionInOneLine = struct { max_length: u32 = 120, a: usize = 123, b: usize = 12354, c: usize = 1234352 };
        \\fn reallyExtraVerboseFunctionNameToThePointOfBeingACodeSmellAndProbablyAHintThatYouCanGetAwayWithAnotherNameOrSplittingThisIntoSeveralFunctions() u32 {
        \\    return 123;
        \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
