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
//! ```

const std = @import("std");
const util = @import("util");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const a = @import("../ast_utils.zig");
const walk = @import("../../visit/walk.zig");

const Semantic = semantic.Semantic;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

fn mustReturnRefDiagnostic(ctx: *LinterContext, type_name: []const u8, returned: Node.Index) Error {
    var e = ctx.diagnosticf(
        "Members of type `{s}` must be passed by reference",
        .{type_name},
        .{ctx.labelN(returned, "This is a copy, not a move.", .{})},
    );
    e.help = Cow.static("This type records its allocation size, so mutating a copy can result in a memory leak.");
    return e;
}

const MustReturnRef = @This();
pub const meta: Rule.Meta = .{
    .name = "must-return-ref",
    .default = .err,
    .category = .suspicious,
};

pub fn runOnNode(_: *const MustReturnRef, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (wrapper.node.tag != .fn_decl) return;

    // const nodes = ctx.ast().nodes;
    // const tags: []const Node.Tag = nodes.items(.tag);

    var buf: [1]Node.Index = undefined;
    // SAFETY: fn decls always have a fn proto
    const decl = ctx.ast().fullFnProto(&buf, wrapper.idx) orelse unreachable;
    const return_type = decl.ast.return_type;
    // const returned_tok: TokenIndex = a.getRightmostIdentifier(ctx, return_type) orelse return;
    const returned_ident = a.getRightmostIdentifier(ctx, return_type) orelse return;
    if (!types_to_check.has(returned_ident)) return;

    // look for member accesses in return statements
    var visitor = ReturnVisitor.new(ctx, returned_ident);
    var stackAlloc = std.heap.stackFallback(512, ctx.gpa);
    var walker = walk.Walker(ReturnVisitor, ReturnVisitor.VisitError).init(
        stackAlloc.get(),
        ctx.ast(),
        &visitor,
    ) catch @panic("oom");
    defer walker.deinit();
    walker.walk() catch @panic("oom");
}

const ReturnVisitor = struct {
    typename: []const u8,
    ctx: *LinterContext,
    datas: []const Node.Data,
    tags: []const Node.Tag,

    pub const VisitError = error{};

    fn new(ctx: *LinterContext, typename: []const u8) ReturnVisitor {
        return .{
            .typename = typename,
            .ctx = ctx,
            .datas = ctx.ast().nodes.items(.data),
            .tags = ctx.ast().nodes.items(.tag),
        };
    }

    pub fn visit_return(self: *ReturnVisitor, node: Node.Index) VisitError!walk.WalkState {
        const returned = self.datas[node].lhs;
        if (returned == Semantic.NULL_NODE) return .Continue; // type error
        // todo: check that leftmost ident is `this`.
        if (self.tags[returned] != .field_access) return .Continue;

        var ctx = self.ctx;
        ctx.report(mustReturnRefDiagnostic(ctx, self.typename, returned));

        return .Continue;
    }
};

const types_to_check = std.StaticStringMap(void).initComptime(&[_]struct { []const u8 }{
    .{"ArenaAllocator"},
    // array list
    .{"ArrayList"},
    .{"ArrayListUnmanaged"},
    .{"AutoArrayHashMap"},
    .{"AutoArrayHashMapUnmanaged"},
    // multi array list
    .{"MultiArrayList"},
    .{"MultiArrayListUnmanaged"},
    // hash map
    .{"AutoHashMap"},
    .{"AutoHashMapUnmanaged"},
    .{"HashMap"},
    .{"HashMapUnmanaged"},
    .{"StringHashMap"},
    .{"StringHashMapUnmanaged"},
});

pub fn rule(self: *MustReturnRef) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test MustReturnRef {
    const t = std.testing;

    var must_return_ref = MustReturnRef{};
    var runner = RuleTester.init(t.allocator, must_return_ref.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        \\const std = @import("std");
        \\const ArenaAllocator = std.mem.ArenaAllocator;
        \\
        \\const Foo = struct {
        \\  pub fn newArena(self: *Foo) ArenaAllocator {
        \\    return createArenaSomehow();
        \\  }
        \\};
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        \\const std = @import("std");
        \\const ArenaAllocator = std.mem.ArenaAllocator;
        \\
        \\const Foo = struct {
        \\  arena: ArenaAllocator,
        \\  pub fn getArena(self: *Foo) ArenaAllocator {
        \\    return self.arena;
        \\  }
        \\};
        ,
        \\pub fn getList(self: *Foo) std.ArrayList(u32) {
        \\  if (!self.has_list) {
        \\    return std.ArrayList(u32).init(self.allocator);
        \\  } else {
        \\    return self.list;
        \\  }
        \\}
        // todo: complex cases
        // \\pub fn getArena(self: *Foo) std.ArrayList(u32) {
        // \\  return if (!self.has_list)
        // \\    std.ArrayList(u32).init(self.arena)
        // \\  else
        // \\    self.list;
        // \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
