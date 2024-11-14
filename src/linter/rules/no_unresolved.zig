const std = @import("std");
const fs = std.fs;
const path = std.fs.path;
const _source = @import("../../source.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Loc = std.zig.Loc;
const Span = _source.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = @import("../rule.zig").Rule;
const NodeWrapper = @import("../rule.zig").NodeWrapper;

pub const NoUnresolved = struct {
    pub const Name = "no-unresolved";

    pub fn runOnNode(_: *const NoUnresolved, wrapper: NodeWrapper, ctx: *LinterContext) void {
        const node = wrapper.node;
        if (ctx.source.pathname == null) return; //   anonymous source file
        if (node.tag != .builtin_call_two) return; // not a node we care about

        const builtin_name = ctx.ast().tokenSlice(node.main_token);
        if (!std.mem.eql(u8, builtin_name, "@import")) {
            return;
        }
        if (node.data.lhs == 0) {
            ctx.diagnostic(
                "Call to `@import()` has no file path or module name.",
                .{ctx.spanN(wrapper.idx)},
            );
        }

        const tags: []Ast.Node.Tag = ctx.ast().nodes.items(.tag);
        const main_tokens = ctx.ast().nodes.items(.main_token);

        // importing with a constant or something. Skip analysis. Maybe in the
        // future we'll resolve references, but Semantic doesn't support that at
        // the time of writing this rule.
        if (tags[node.data.lhs] != .string_literal) {
            return;
        }
        const pathname_str = ctx.ast().tokenSlice(main_tokens[node.data.lhs]);
        var pathname = std.mem.trim(u8, pathname_str, "\"");

        // if it's not a .zig import, ignore it
        {
            // 2 for open/close quotes
            if (pathname.len < 4) return;
            const ext = pathname[pathname.len - 4 ..];
            if (!std.mem.eql(u8, ext, ".zig")) return;
        }

        // join it with the current file's folder to get where it would be
        {
            // note: pathname null check performed at start of function
            const dirname = path.dirname(ctx.source.pathname.?) orelse return;
            // FIXME: do not use fs.cwd(). this will break once users start
            // specifying paths to lint. We should be recording an absolute path
            // for each linted file.
            const dir = fs.cwd().openDir(dirname, .{}) catch std.debug.panic("Failed to open dir: {s}", .{dirname});
            const stat = dir.statFile(pathname) catch {
                ctx.diagnosticAlloc(
                    std.fmt.allocPrint(ctx.gpa, "Unresolved import to '{s}'", .{pathname}) catch @panic("oom"),
                    .{ctx.spanN(node.data.lhs)},
                );
                return;
            };
            if (stat.kind == .directory) {
                ctx.diagnosticAlloc(
                    std.fmt.allocPrint(ctx.gpa, "Unresolved import to directory '{s}'", .{pathname}) catch @panic("oom"),
                    .{ctx.spanN(node.data.lhs)},
                );
            }
        }
    }

    pub fn rule(self: *NoUnresolved) Rule {
        return Rule.init(self);
    }
};

test {
    std.testing.refAllDecls(@This());
}