//! ## What This Rule Does
//! Disallows returning copies of types that store a `capacity`.
//!
//! Zig does not have move semantics. Returning a value by value copies it.
//! Returning a copy of a struct's field that records how much memory it has
//! allocated can easily lead to memory leaks.
//!
//! ```zig
//! const std = @import("std");
//! pub const Foo = struct {
//!   list: std.ArrayList(u32),
//!   pub fn getList(self: *Foo) std.ArrayList(u32) {
//!       return self.list;
//!   }
//! };
//!
//! pub fn main() !void {
//!   var foo: Foo = .{
//!     .list = try std.ArrayList(u32).init(std.heap.page_allocator)
//!   };
//!   defer foo.list.deinit();
//!   var list = foo.getList();
//!   try list.append(1); // leaked!
//! }
//! ```
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn foo(self: *Foo) std.ArrayList(u32) {
//!   return self.list;
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! // pass by reference
//! fn foo(self: *Foo) *std.ArrayList(u32) {
//!   return &self.list;
//! }
//!
//! // new instances are fine
//! fn foo() ArenaAllocator {
//!   return std.mem.ArenaAllocator.init(std.heap.page_allocator);
//! }
//! ```

const std = @import("std");
const util = @import("util");
const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");

const a = @import("../ast_utils.zig");
const walk = @import("../../visit/walk.zig");

const zig = @import("../../zig.zig").@"0.14.1";
const Ast = zig.Ast;
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
    .default = .warning,
    .category = .suspicious,
};

pub fn runOnNode(_: *const MustReturnRef, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (wrapper.node.tag != .fn_decl) return;

    var buf: [1]Node.Index = undefined;
    // SAFETY: fn decls always have a fn proto
    const decl = ctx.ast().fullFnProto(&buf, wrapper.idx) orelse unreachable;
    const body = wrapper.node.data.rhs;
    std.debug.assert(body != Semantic.NULL_NODE);
    const return_type = decl.ast.return_type;
    const returned_ident = a.getRightmostIdentifier(ctx, return_type) orelse return;
    if (!types_to_check.has(returned_ident)) return;

    // look for member accesses in return statements
    var visitor = ReturnVisitor.new(ctx, returned_ident);
    var stackAlloc = std.heap.stackFallback(512, ctx.gpa);
    var walker = walk.Walker(ReturnVisitor, ReturnVisitor.VisitError).initAtNode(
        stackAlloc.get(),
        ctx.ast(),
        &visitor,
        body,
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
        if (returned == Semantic.NULL_NODE) return .Continue; // fn is missing return type, which is a semantic error
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
        ,
        \\const Foo = struct {
        \\  pub fn newArena(self: *Foo) ArenaAllocator {
        \\    return self.createArena();
        \\  }
        \\};
        ,
        \\pub fn copyLatin1IntoUTF16(comptime Buffer: type, buf_: Buffer, comptime Type: type, latin1_: Type) EncodeIntoResult {
        \\    var buf = buf_;
        \\    var latin1 = latin1_;
        \\    while (buf.len > 0 and latin1.len > 0) {
        \\        const to_write = strings.firstNonASCII(latin1) orelse @as(u32, @truncate(@min(latin1.len, buf.len)));
        \\        if (comptime std.meta.alignment(Buffer) != @alignOf(u16)) {
        \\            strings.copyU8IntoU16WithAlignment(std.meta.alignment(Buffer), buf, latin1[0..to_write]);
        \\        } else {
        \\            strings.copyU8IntoU16(buf, latin1[0..to_write]);
        \\        }
        \\
        \\        latin1 = latin1[to_write..];
        \\        buf = buf[to_write..];
        \\        if (latin1.len > 0 and buf.len >= 1) {
        \\            buf[0] = latin1ToCodepointBytesAssumeNotASCII16(latin1[0]);
        \\            latin1 = latin1[1..];
        \\            buf = buf[1..];
        \\        }
        \\    }
        \\
        \\    return .{
        \\        .read = @as(u32, @truncate(buf_.len - buf.len)),
        \\        .written = @as(u32, @truncate(latin1_.len - latin1.len)),
        \\    };
        \\}
        \\pub fn elementLengthLatin1IntoUTF16(comptime Type: type, latin1_: Type) usize {
        \\    // latin1 is always at most 1 UTF-16 code unit long
        \\    if (comptime std.meta.Child([]const u16) == Type) {
        \\        return latin1_.len;
        \\    }
        \\
        \\    var count: usize = 0;
        \\    var latin1 = latin1_;
        \\    while (latin1.len > 0) {
        \\        const function = comptime if (std.meta.Child(Type) == u8) strings.firstNonASCIIWithType else strings.firstNonASCII16;
        \\        const to_write = function(Type, latin1) orelse @as(u32, @truncate(latin1.len));
        \\        count += to_write;
        \\        latin1 = latin1[to_write..];
        \\        if (latin1.len > 0) {
        \\            count += comptime if (std.meta.Child(Type) == u8) 2 else 1;
        \\            latin1 = latin1[1..];
        \\        }
        \\    }
        \\
        \\    return count;
        \\}
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
