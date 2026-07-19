//! ## What This Rule Does
//! Limits the total [cognitive complexity](https://www.sonarsource.com/docs/CognitiveComplexity.pdf)
//! of an entire source file.
//!
//! The file score is the sum of the cognitive complexity of everything in the
//! file: all functions and test blocks (each scored with nesting reset to 0,
//! exactly as the `cognitive-complexity` rule scores them) plus any
//! container-level code such as `comptime` blocks and global variable
//! initializers. See the `cognitive-complexity` rule for how individual
//! constructs are scored.
//!
//! Files with a high total are usually doing too much and are candidates for
//! being split up, even when every individual function stays under its
//! per-function budget.
//!
//! This check is disabled until a maximum is configured:
//!
//! ```json
//! {
//!   "rules": {
//!     "cognitive-complexity-file": ["warn", { "max_complexity": 100 }]
//!   }
//! }
//! ```
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule (with `max_complexity: 8`):
//! ```zig
//! fn sumOfPrimes(max: u32) u32 { // score: 7
//!     var total: u32 = 0;
//!     outer: for (1..max) |i| {
//!         var j: u32 = 2;
//!         while (j < i) : (j += 1) {
//!             if (i % j == 0) continue :outer;
//!         }
//!         total += i;
//!     }
//!     return total;
//! }
//!
//! fn classify(c: bool) u32 { // score: 2; file total: 9
//!     const x: u32 = if (c) 1 else 2;
//!     return x;
//! }
//! ```
//!
//! Examples of **correct** code for this rule (with `max_complexity: 8`):
//! ```zig
//! fn getWords(n: u32) []const u8 { // score: 1
//!     return switch (n) {
//!         1 => "one",
//!         2 => "a couple",
//!         else => "lots",
//!     };
//! }
//!
//! fn isPrime(n: u32) bool { // score: 3; file total: 4
//!     if (n < 2) return false;
//!     for (2..n) |i| {
//!         if (n % i == 0) return false;
//!     }
//!     return true;
//! }
//! ```

const std = @import("std");
const util = @import("util");
const _rule = @import("../rule.zig");
const cc = @import("../cognitive_complexity.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const CognitiveComplexityFile = @This();
pub const meta: Rule.Meta = .{
    .name = "cognitive-complexity-file",
    .category = .restriction,
    // opt-in metric rule
    .default = .off,
};

/// Maximum allowed total cognitive complexity per file. 0 disables the check.
max_complexity: u32 = 0,

pub fn runOnce(self: *const CognitiveComplexityFile, ctx: *LinterContext) void {
    if (self.max_complexity == 0) return;

    const result = cc.scoreFile(ctx);
    defer ctx.gpa.free(result.increments);
    if (result.score <= self.max_complexity) return;

    const filename = ctx.source.pathname orelse "anonymous source file";
    var d = ctx.diagnosticf(
        "{s}: cognitive complexity is {d}, which exceeds the maximum of {d}.",
        .{ filename, result.score, self.max_complexity },
        .{},
    );
    d.help = Cow.static("Split large functions into smaller ones, or move unrelated code into its own file.");
    ctx.report(d);
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *CognitiveComplexityFile) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test CognitiveComplexityFile {
    const t = std.testing;

    var cognitive_complexity_file = CognitiveComplexityFile{ .max_complexity = 10 };
    var runner = RuleTester.init(t.allocator, cognitive_complexity_file.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // empty file: 0
        "",
        // 7 + 2 = 9
        \\fn sumOfPrimes(max: u32) u32 {
        \\  var total: u32 = 0;
        \\  outer: for (1..max) |i| {
        \\    var j: u32 = 2;
        \\    while (j < i) : (j += 1) {
        \\      if (i % j == 0) continue :outer;
        \\    }
        \\    total += i;
        \\  }
        \\  return total;
        \\}
        \\fn classify(c: bool) u32 {
        \\  const x: u32 = if (c) 1 else 2;
        \\  return x;
        \\}
        ,
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // function scores sum: 7 + 6 = 13
        \\fn sumOfPrimes(max: u32) u32 {
        \\  var total: u32 = 0;
        \\  outer: for (1..max) |i| {
        \\    var j: u32 = 2;
        \\    while (j < i) : (j += 1) {
        \\      if (i % j == 0) continue :outer;
        \\    }
        \\    total += i;
        \\  }
        \\  return total;
        \\}
        \\fn f(a: bool, b: bool, c: bool) void {
        \\  if (a) {
        \\    if (b) {
        \\      if (c) {}
        \\    }
        \\  }
        \\}
        ,
        // container-level code counts too: 7 + 6 = 13
        \\const builtin = @import("builtin");
        \\comptime {
        \\  if (builtin.os.tag == .linux) {
        \\    if (builtin.cpu.arch == .x86_64) {
        \\      if (builtin.abi == .gnu) {}
        \\    }
        \\  }
        \\}
        \\fn sumOfPrimes(max: u32) u32 {
        \\  var total: u32 = 0;
        \\  outer: for (1..max) |i| {
        \\    var j: u32 = 2;
        \\    while (j < i) : (j += 1) {
        \\      if (i % j == 0) continue :outer;
        \\    }
        \\    total += i;
        \\  }
        \\  return total;
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
