//! ## What This Rule Does
//! Limits the [cognitive complexity](https://www.sonarsource.com/docs/CognitiveComplexity.pdf)
//! of functions and test blocks.
//!
//! Cognitive complexity measures how hard code is to follow. Unlike cyclomatic
//! complexity, it penalizes nesting: a deeply nested `if` costs more than a
//! flat one, while a `switch` with many cases costs the same as a single `if`.
//!
//! Scores follow the SonarSource white paper, as implemented by
//! [gocognit](https://github.com/uudashr/gocognit) and SonarSource rule
//! S3776, mapped to Zig constructs:
//!
//! - **+1 plus nesting level**: `if`, `while`, `for`, `switch` (the whole
//!   switch, not each case), and `catch` with a block handler.
//! - **+1, no nesting penalty**: `else if` and plain `else`, on both `if` and
//!   loops (e.g. `while (...) { ... } else { ... }`).
//! - **+1**: each sequence of like boolean operators (`a and b and c` is +1,
//!   `a and b or c` is +2), each labeled `break`/`continue`, and each direct
//!   self-recursive call.
//!
//! ### What does not count
//!
//! `orelse`, `try`, shorthand `catch` handlers (`catch unreachable`,
//! `catch return err`), early `return`, unlabeled `break`/`continue`, and
//! `defer`/`errdefer` are idiomatic shorthand and are free. An if-expression
//! (`const x = if (c) a else b;`) counts as an `if` plus an `else` (2), just
//! like an if statement. Test blocks are scored like functions. Functions
//! declared inside other functions are scored independently.
//!
//! The maximum is configurable:
//!
//! ```json
//! {
//!   "rules": {
//!     "cognitive-complexity": ["warn", { "max_complexity": 15 }]
//!   }
//! }
//! ```
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule (with `max_complexity: 4`):
//! ```zig
//! fn sumOfPrimes(max: u32) u32 { // score: 7
//!     var total: u32 = 0;
//!     outer: for (1..max) |i| {      // +1
//!         var j: u32 = 2;
//!         while (j < i) : (j += 1) { // +2 (nesting = 1)
//!             if (i % j == 0) {      // +3 (nesting = 2)
//!                 continue :outer;   // +1
//!             }
//!         }
//!         total += i;
//!     }
//!     return total;
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn getWords(n: u32) []const u8 { // score: 1
//!     return switch (n) {          // +1
//!         1 => "one",
//!         2 => "a couple",
//!         else => "lots",
//!     };
//! }
//! ```

const std = @import("std");
const util = @import("util");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const cc = @import("../cognitive_complexity.zig");

const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const CognitiveComplexity = @This();
pub const meta: Rule.Meta = .{
    .name = "cognitive-complexity",
    .category = .restriction,
    // opt-in metric rule
    .default = .off,
};

/// Maximum allowed cognitive complexity per function or test block.
max_complexity: u32 = 15,

pub fn runOnNode(self: *const CognitiveComplexity, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const tag = wrapper.node.tag;
    if (tag != .fn_decl and tag != .test_decl) return;

    const result = cc.scoreFunction(ctx, wrapper.idx);
    defer ctx.gpa.free(result.increments);
    if (result.score <= self.max_complexity) return;

    ctx.report(self.complexityDiagnostic(ctx, wrapper.idx, tag, result));
}

fn complexityDiagnostic(
    self: *const CognitiveComplexity,
    ctx: *LinterContext,
    decl: Node.Index,
    tag: Node.Tag,
    result: cc.Result,
) Error {
    const ast = ctx.ast();

    var labels: std.ArrayListUnmanaged(LabeledSpan) = .empty;
    defer labels.deinit(ctx.gpa);

    var d: Error = switch (tag) {
        .fn_decl => blk: {
            var buf: [1]Node.Index = undefined;
            // SAFETY: fn decls always have a fn proto
            const proto = ast.fullFnProto(&buf, decl) orelse unreachable;
            const name_tok: TokenIndex = proto.name_token orelse proto.ast.fn_token;
            labels.append(ctx.gpa, ctx.labelT(name_tok, "complexity is {d}", .{result.score})) catch @panic("OOM");
            appendIncrementLabels(ctx, &labels, result.increments);
            break :blk ctx.diagnosticf(
                "Cognitive complexity of function '{s}' is {d}, which exceeds the maximum of {d}.",
                .{ ctx.semantic.tokenSlice(name_tok), result.score, self.max_complexity },
                labels.items,
            );
        },
        .test_decl => blk: {
            const data = ast.nodeData(decl).opt_token_and_node;
            const name_tok: TokenIndex = data[0].unwrap() orelse ast.nodeMainToken(decl);
            const name: []const u8 = if (data[0].unwrap()) |t| ctx.semantic.tokenSlice(t) else "(anonymous)";
            labels.append(ctx.gpa, ctx.labelT(name_tok, "complexity is {d}", .{result.score})) catch @panic("OOM");
            appendIncrementLabels(ctx, &labels, result.increments);
            break :blk ctx.diagnosticf(
                "Cognitive complexity of test {s} is {d}, which exceeds the maximum of {d}.",
                .{ name, result.score, self.max_complexity },
                labels.items,
            );
        },
        else => unreachable,
    };
    d.help = Cow.static("Extract nested blocks into smaller functions; prefer `switch` over long `else if` chains and early returns over deep nesting.");
    return d;
}

/// One secondary label per scored construct, e.g. `+2 (incl. 1 for nesting)`.
fn appendIncrementLabels(
    ctx: *LinterContext,
    labels: *std.ArrayListUnmanaged(LabeledSpan),
    increments: []const cc.Increment,
) void {
    labels.ensureUnusedCapacity(ctx.gpa, increments.len) catch @panic("OOM");
    for (increments) |inc| {
        const label = if (inc.nesting > 0)
            ctx.labelT(inc.token, "+{d} (incl. {d} for nesting)", .{ inc.inc, inc.nesting })
        else
            ctx.labelT(inc.token, "+{d}", .{inc.inc});
        labels.appendAssumeCapacity(label);
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *CognitiveComplexity) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test CognitiveComplexity {
    const t = std.testing;

    var cognitive_complexity = CognitiveComplexity{ .max_complexity = 3 };
    var runner = RuleTester.init(t.allocator, cognitive_complexity.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // empty function: 0
        \\fn foo() void {}
        ,
        // if / else if / else: 1 + 1 + 1 = 3
        \\fn getWords(n: u32) []const u8 {
        \\  if (n == 1) {
        \\    return "one";
        \\  } else if (n == 2) {
        \\    return "a couple";
        \\  } else {
        \\    return "lots";
        \\  }
        \\}
        ,
        // a switch and all its cases: 1
        \\fn getWords(n: u32) []const u8 {
        \\  return switch (n) {
        \\    1 => "one",
        \\    2 => "a couple",
        \\    3 => "a few",
        \\    else => "lots",
        \\  };
        \\}
        ,
        // sequence of like operators: 1
        \\fn f(a: bool, b: bool, c: bool) bool {
        \\  return a and b and c;
        \\}
        ,
        // shorthand catch, orelse, try: 0
        \\fn f(x: anyerror!u32, y: ?u32) anyerror!u32 {
        \\  const a = x catch return 0;
        \\  const b = y orelse 0;
        \\  _ = try x;
        \\  return a + b;
        \\}
        ,
        // unlabeled break is free: while = 1
        \\fn f() void {
        \\  while (true) {
        \\    break;
        \\  }
        \\}
        ,
        // if-expression: if + else = 2
        \\fn f(c: bool) u32 {
        \\  const x: u32 = if (c) 1 else 2;
        \\  return x;
        \\}
        ,
        // labeled breaks from a block: if 1 + break 1 + break 1 = 3
        \\fn f(a: bool) u32 {
        \\  const x = blk: {
        \\    if (a) break :blk 1;
        \\    break :blk 0;
        \\  };
        \\  return x;
        \\}
        ,
        // nested functions are scored independently: outer is 0, inner is 1
        \\fn outer() void {
        \\  const S = struct {
        \\    fn inner() void {
        \\      if (true) {}
        \\    }
        \\  };
        \\  _ = S;
        \\}
        ,
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // nested loops + labeled continue: for 1 + while 2 + if 3 + continue 1 = 7
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
        // nesting penalty: if 1 + if 2 + if 3 = 6
        \\fn f(a: bool, b: bool, c: bool) void {
        \\  if (a) {
        \\    if (b) {
        \\      if (c) {}
        \\    }
        \\  }
        \\}
        ,
        // if + else + nested if: 1 + 1 + 2 = 4
        \\fn f(a: bool, b: bool) void {
        \\  if (a) {} else {
        \\    if (b) {}
        \\  }
        \\}
        ,
        // else if raises no nesting: if 1 + else if 1 + if 2 = 4
        \\fn f(a: bool, b: bool, c: bool) void {
        \\  if (a) {} else if (b) {
        \\    if (c) {}
        \\  }
        \\}
        ,
        // catch with a block handler: catch 1 + if 2 + if 3 = 6
        \\fn f(x: anyerror!u32) u32 {
        \\  return x catch |err| {
        \\    if (err == error.Foo) {
        \\      if (err == error.Bar) return 0;
        \\    }
        \\    return 1;
        \\  };
        \\}
        ,
        // loop else: while 1 + if 2 + else 1 = 4
        \\fn f(a: bool, b: bool) void {
        \\  while (a) {
        \\    if (b) break;
        \\  } else {
        \\    @panic("no break");
        \\  }
        \\}
        ,
        // direct recursion: if 1 + else 1 + call 1 + call 1 = 4
        \\fn fib(n: u32) u32 {
        \\  if (n < 2) return n else return fib(n - 1) + fib(n - 2);
        \\}
        ,
        // mixed operator sequences: if 1 + and 1 + or 1 + and 1 = 4
        \\fn f(a: bool, b: bool, c: bool, d: bool) void {
        \\  if ((a and b or c) and d) {}
        \\}
        ,
        // error union if with payload captures: if 1 + else 1 + if 2 = 4
        \\fn f(x: anyerror!u32) u32 {
        \\  if (x) |v| {
        \\    return v;
        \\  } else |err| {
        \\    if (err == error.Foo) return 0;
        \\    return 1;
        \\  }
        \\}
        ,
        // test blocks are scored: 6
        \\test "complex" {
        \\  if (true) {
        \\    if (true) {
        \\      if (true) {}
        \\    }
        \\  }
        \\}
        ,
        // nested functions are scored independently: only inner is reported (6)
        \\fn outer() void {
        \\  const S = struct {
        \\    fn inner() void {
        \\      if (true) {
        \\        if (true) {
        \\          if (true) {}
        \\        }
        \\      }
        \\    }
        \\  };
        \\  _ = S;
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
