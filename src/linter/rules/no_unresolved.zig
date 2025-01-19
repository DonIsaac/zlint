//! ## What This Rule Does
//!
//! Checks for imports to files that do not exist.
//!
//! This rule only checks for file-based imports. Modules added by `build.zig`
//! are not checked. More precisely, imports to paths ending in `.zig` will be
//! resolved. This rule checks that a file exists at the imported path and is
//! not a directory. Symlinks are allowed but are not followed.
//!
//! ## Examples
//! Assume the following directory structure:
//! ```plaintext
//! .
//! ├── foo.zig
//! ├── mod
//! │   └── bar.zig
//! ├── not_a_file.zig
//! │   └── baz.zig
//! └── root.zig
//! ```
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! // root.zig
//! const x = @import("mod/foo.zig");    // foo.zig is in the root directory.
//! const y = @import("not_a_file.zig"); // directory, not a file
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! // root.zig
//! const x = @import("foo.zig");
//! const y = @import("mod/bar.zig");
//! ```
const std = @import("std");
const util = @import("util");
const fs = std.fs;
const path = std.fs.path;

const Ast = std.zig.Ast;
const LinterContext = @import("../lint_context.zig");
const Rule = @import("../rule.zig").Rule;
const NodeWrapper = @import("../rule.zig").NodeWrapper;

const NoUnresolved = @This();
pub const meta: Rule.Meta = .{
    .name = "no-unresolved",
    .category = .correctness,
    .default = .err,
};

pub fn runOnNode(_: *const NoUnresolved, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    if (ctx.source.pathname == null) return; //   anonymous source file
    if (node.tag != .builtin_call_two) return; // not a node we care about

    const builtin_name = ctx.semantic.tokenSlice(node.main_token);
    if (!std.mem.eql(u8, builtin_name, "@import")) {
        return;
    }
    if (node.data.lhs == 0) {
        ctx.report(ctx.diagnostic(
            "Call to `@import()` has no file path or module name.",
            .{ctx.spanN(wrapper.idx)},
        ));
        return;
    }

    const tags: []Ast.Node.Tag = ctx.ast().nodes.items(.tag);
    const main_tokens = ctx.ast().nodes.items(.main_token);

    // Note: this will get caught by ast check
    if (tags[node.data.lhs] != .string_literal) {
        ctx.report(ctx.diagnostic("@import operand must be a string literal", .{ctx.spanN(node.data.lhs)}));
        return;
    }
    const pathname_str = ctx.semantic.tokenSlice(main_tokens[node.data.lhs]);
    var pathname = std.mem.trim(u8, pathname_str, "\"");

    // if it's not a .zig import, ignore it
    {
        // 2 for open/close quotes
        if (pathname.len < 4) return;
        const ext = pathname[pathname.len - 4 ..];
        if (!isDotSlash(ext) and !std.mem.eql(u8, ext, ".zig")) return;
    }

    // join it with the current file's folder to get where it would be
    {
        // NOTE: pathname null check performed at start of function
        const dirname = path.dirname(ctx.source.pathname.?) orelse return;
        // FIXME: do not use fs.cwd(). this will break once users start
        // specifying paths to lint. We should be recording an absolute path
        // for each linted file.
        var dir = fs.cwd().openDir(dirname, .{}) catch std.debug.panic("Failed to open dir: {s}", .{dirname});
        defer dir.close();
        // TODO: use absolute paths and cache stat results.
        // depends on: https://github.com/DonIsaac/zlint/issues/81
        const stat = dir.statFile(pathname) catch {
            ctx.report(ctx.diagnosticf(
                "Unresolved import to '{s}'",
                .{pathname},
                .{ctx.labelN(node.data.lhs, "file '{s}' does not exist", .{pathname})},
            ));
            return;
        };
        if (stat.kind == .directory) {
            ctx.report(ctx.diagnosticf(
                "Unresolved import to directory '{s}'",
                .{pathname},
                .{ctx.labelN(node.data.lhs, "'{s}' is a folder", .{pathname})},
            ));
        }
    }
}

fn isDotSlash(pathname: []const u8) bool {
    if (pathname.len < 2) return false;
    return pathname[0] == '.' and (pathname[1] == '/' or (util.IS_DEBUG and pathname[1] == '\\'));
}

pub fn rule(self: *NoUnresolved) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoUnresolved {
    const t = std.testing;

    var no_unresolved = NoUnresolved{};
    var runner = RuleTester.init(t.allocator, no_unresolved.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "const std = @import(\"std\");",
        "const x = @import(\"main.zig\");",
    };
    const fail = &[_][:0]const u8{
        \\const x = @import("does-not-exist.zig");
        ,
        // TODO: dir.statFile() returns .{ .kind = .file } even for directories
        // \\const x = @import("./walk");
        // TODO: currently caught by semantic analysis. Right now sema failures
        // make the linter panic. uncomment when sema failures are handled
        // "const p = \"foo.zig\"\nconst x = @import(foo);",
    };

    try runner
        .withPath("src")
        .withPass(pass)
        .withFail(fail)
        .run();
}
