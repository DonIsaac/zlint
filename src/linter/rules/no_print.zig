//! ## What This Rule Does
//! Disallows the use of `std.debug.print`.
//!
//! `print` statements are great for debugging, but they should be removed
//! before code gets merged. When you need debug logs in production, use
//! `std.log` instead.
//!
//! This rule makes a best-effort attempt to ensure `print` calls are actually
//! from `std.debug.print`. It will not report calls to custom print functions
//! if they are defined within the same file. If you are getting false positives
//! because you import a custom print function, consider disabling this rule on
//! a file-by-file basis instead of turning it off globally.
//!
//! ### Tests
//! By default, this rule ignores `print`s in test blocks and files. Files are
//! considered to be a test file if they end with `test.zig`. You may disable
//! this by setting `allow_tests` to `false` in the rule's metadata.
//!
//! ```json
//! {
//!   "rules": {
//!     "no-print": ["warn", { "allow_tests": false }]
//!   }
//! }
//! ```
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const std = @import("std");
//! const debug = std.debug;
//! const print = std.debug.print;
//! fn main() void {
//!     std.debug.print("This should not be here: {d}\n", .{42});
//!     debug.print("This should not be here: {d}\n", .{42});
//!     print("This should not be here: {d}\n", .{42});
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const std = @import("std");
//! fn foo() u32 {
//!     std.log.debug("running foo", .{});
//!     return 1;
//! }
//!
//! test foo {
//!     std.debug.print("testing foo\n", .{});
//!     try std.testing.expectEqual(1, foo());
//! }
//! ```
//!
//! ```zig
//! fn print(comptime msg: []const u8, args: anytype) void {
//!     // ...
//! }
//! fn main() void {
//!     print("Staring program", .{});
//! }
//! ```

const std = @import("std");
const util = @import("util");
const ast_utils = @import("../ast_utils.zig");
const _source = @import("../../source.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const zig = @import("../../zig.zig").@"0.14.1";

const Loc = zig.Token.Loc;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Symbol = Semantic.Symbol;
const Scope = Semantic.Scope;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);
const eql = std.mem.eql;

pub const meta: Rule.Meta = .{
    .name = "no-print",
    .category = .restriction,
    .default = .warning,
};

const NoPrint = @This();

/// Do not report print calls in test blocks or files.
allow_tests: bool = true,

fn noPrintDiagnostic(ctx: *LinterContext, span: Span) Error {
    var d = ctx.diagnostic(
        "Using `std.debug.print` is not allowed.",
        .{LabeledSpan{ .span = span }},
    );
    d.help = .static("End-users don't want to see debug logs. Use `std.log` instead.");
    return d;
}

pub fn runOnNode(self: *const NoPrint, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;

    switch (node.tag) {
        .call, .call_comma => {},
        else => return,
    }
    if (self.allow_tests) {
        // check if we're inside a test block
        if (ast_utils.isInTest(ctx, wrapper.idx)) {
            return;
        }
        if (ctx.source.pathname) |pathname| {
            if (std.mem.endsWith(u8, pathname, "test.zig")) {
                return; // skip test files
            }
        }
    }
    const nodes = ctx.ast().nodes;
    const tags: []const Node.Tag = nodes.items(.tag);

    const callee = node.data.lhs;
    // SAFETY: initialized below. if not found, or identifier is not "print",
    // rule returns before this is used.
    var print_span: Span = undefined;

    switch (tags[callee]) {
        // look for `print(msg, args);`
        .identifier => {
            const ident_tok: TokenIndex = nodes.items(.main_token)[callee];
            std.debug.assert(ctx.ast().tokens.items(.tag)[ident_tok] == .identifier);
            const ident_span = ctx.semantic.tokenSpan(ident_tok);

            if (!eql(u8, "print", ident_span.snippet(ctx.source.text()))) {
                return;
            }

            // this may be a call to a locally-defined, custom print function
            check_local_print: {
                const decl = ctx.semantic.resolveBinding(
                    ctx.links().getScope(callee) orelse break :check_local_print,
                    "print",
                    .{ .exclude = .{ .s_variable = true } },
                );
                if (decl != null) return;
            }
            // FIXME: references do fns do not appear to be working
            // if (ctx.links().references.get(callee)) |symbol_id| {
            //     // is this a call to a custom print function?
            //     const flags: Symbol.Flags = ctx.symbols().symbols.items(.flags)[symbol_id.int()];
            //     if (flags.s_fn) {
            //         return;
            //     }
            // }

            print_span = ident_span;
        },
        // look for `std.debug.print(msg, args);`
        .field_access => {
            const field_access: Node.Data = nodes.items(.data)[callee];

            const ident_tok: TokenIndex = field_access.rhs;
            std.debug.assert(ctx.ast().tokens.items(.tag)[ident_tok] == .identifier);
            const field_span = ctx.semantic.tokenSpan(ident_tok);
            if (!eql(u8, "print", field_span.snippet(ctx.source.text()))) {
                return;
            }

            const maybe_debug: []const u8 = ast_utils.getRightmostIdentifier(ctx, field_access.lhs) orelse {
                return; // not a field access with an identifier
            };
            if (!eql(u8, "debug", maybe_debug)) {
                return; // not `debug.print()`, probably `writer.print()` (which is fine)
            }

            print_span = field_span;
        },
        else => return,
    }

    ctx.report(noPrintDiagnostic(ctx, print_span));
}

pub fn rule(self: *NoPrint) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoPrint {
    const t = std.testing;

    var no_print = NoPrint{};
    var runner = RuleTester.init(t.allocator, no_print.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        \\fn foo(Writer: type, w: *Writer) !void {
        \\  w.print("writers are allowed", .{});
        \\}
        ,
        \\fn add(a: u32, b: u32) u32 {
        \\  return a + b;
        \\}
        \\test add {
        \\  const std = @import("std");
        \\  std.debug.print("testing add({d}, {d})\n", .{1, 2});
        \\  try std.testing.expectEqual(3, add(1, 2));
        \\}
        ,
        \\fn print(comptime msg: []const u8, args: anytype) void {
        \\  // some custom print function
        \\  _ = msg;
        \\  _ = args;
        \\}
        \\fn main() void {
        \\  print("This is a custom print function", .{});
        \\}
        ,
        \\const print = @import("custom_print.zig").print;
        \\fn main() void {
        \\  print("this has a different signature so it wont get reported");
        \\}
        ,
        \\const println = @import("custom_print.zig").println;
        \\fn main() void {
        \\  println("std.debug has no println function so it should not get reported", .{});
        \\}
        ,
    };

    const fail = &[_][:0]const u8{
        \\const std = @import("std");
        \\fn foo() void {
        \\  std.debug.print("This should not be here: {d}\n", .{42});
        \\}
        ,
        \\const std = @import("std");
        \\const debug = std.debug;
        \\fn foo() void {
        \\  debug.print("This should not be here: {d}\n", .{42});
        \\}
        ,
        \\const std = @import("std");
        \\const print = std.debug.print;
        \\fn foo() void {
        \\  print("This should not be here: {d}\n", .{42});
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
