const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = std.zig.Ast;
const Node = Ast.Node;

const Walker = @import("./walk.zig").Walker;
const WalkState = @import("./walk.zig").WalkState;

const t = std.testing;
const expect = t.expect;
const expectEqual = t.expectEqual;

test "Walker calls generic tag visitors if special cases aren't present" {
    const TestVisitor = struct {
        seen_var_decl: bool = false,

        pub const Error = error{};
        pub fn visit_simple_var_decl(self: *@This(), _: Node.Index) Error!WalkState {
            self.seen_var_decl = true;
            return .Continue;
        }
    };

    var ast = try Ast.parse(t.allocator, "const x = 1;", .zig);
    defer ast.deinit(t.allocator);
    var visitor: TestVisitor = .{};
    var walker = try Walker(TestVisitor, TestVisitor.Error).init(t.allocator, &ast, &visitor);
    defer walker.deinit();

    try walker.walk();
    try t.expect(visitor.seen_var_decl);
}

// =============================================================================

const XVisitor = struct {
    // # times we've seen a variable `x`
    seen_x: u32 = 0,
    ast: *const Ast,

    pub const Error = anyerror;

    pub fn visitVarDecl(this: *XVisitor, var_decl: Node.Index, _: *const Ast.full.VarDecl) Error!WalkState {
        const ident = this.ast.nodes.items(.main_token)[var_decl] + 1;
        try t.expectEqual(.identifier, this.ast.tokens.items(.tag)[ident]);
        const name = this.ast.tokenSlice(ident);
        if (std.mem.eql(u8, name, "x")) {
            this.seen_x += 1;
        }
        return .Continue;
    }

    pub fn visit_identifier(this: *XVisitor, ident: Node.Index) Error!WalkState {
        const name = this.ast.getNodeSource(ident);
        if (std.mem.eql(u8, name, "x")) {
            this.seen_x += 1;
        }
        return .Continue;
    }
};

fn testXSeenTimes(expected: u32, src: [:0]const u8) !void {
    const allocator = std.testing.allocator;

    var ast = try Ast.parse(allocator, src, .zig);
    defer ast.deinit(allocator);
    var visitor: XVisitor = .{ .ast = &ast };
    var walker = try Walker(XVisitor, XVisitor.Error).init(std.testing.allocator, &ast, &visitor);
    defer walker.deinit();

    try walker.walk();
    try std.testing.expectEqual(expected, visitor.seen_x);
}

test "where's waldo, but its `x`" {
    try testXSeenTimes(1, "const x = 1;");
    try testXSeenTimes(1,
        \\fn foo() void {
        \\  const x = 2;
        \\}
    );
    try testXSeenTimes(1,
        \\fn foo() void {
        \\  // force .block instead of .block_two
        \\  const a = 1;
        \\  const b = 1;
        \\  const c = 1;
        \\  const d = 1;
        \\
        \\  const x = 2;
        \\}
    );
    try testXSeenTimes(1, "const y = x + 1;");
    try testXSeenTimes(1, "const y = a + (x + 1);");
    try testXSeenTimes(1, "(1 + (2 - (3 / (4 * (1 + 1 + 1 + x)))));");
    try testXSeenTimes(1, "x.y.z");
    try testXSeenTimes(0, "y.x"); // members are not identifiers. This may change in the future.
    try testXSeenTimes(0, "y.x.z");
    try testXSeenTimes(1, "x.?");
    try testXSeenTimes(1, "x.*");
    try testXSeenTimes(0, "pub fn x() void {}"); // fn names aren't identifiers rn.
    try testXSeenTimes(1, "x()");
    try testXSeenTimes(1, "foo(x);");
    try testXSeenTimes(1, "fn y() void { return x; }");
    try testXSeenTimes(1, "fn main() void { defer x; }");
    try testXSeenTimes(1, "fn main() void { errdefer x; }");
    try testXSeenTimes(1, "comptime { _ = x; }");
    try testXSeenTimes(1, "fn main() void { if(x) {} }");
    try testXSeenTimes(1, "fn main() void { while(x) {} }");
    try testXSeenTimes(1, "fn main() void { for(x) {} }");
    try testXSeenTimes(1, "const x = struct{};");
    try testXSeenTimes(1, "const Foo = struct{ pub const y = 1; pub const z = 2; pub const x = 3;};");
    try testXSeenTimes(1, "const y = blk: { break :blk x; };");
    try testXSeenTimes(1, "const y = &[_]const u8{\"foo\", x}");

    try testXSeenTimes(1,
        \\fn main() void {
        \\  if (a) {
        \\    return y;
        \\  } else {
        \\    return x;
        \\  }
        \\}
    );

    // try testXSeenTimes(3,
    //     \\fn foo(x: u32) void {
    //     \\  const a = 1 + (2 - (3 / (4 * x)));
    //     \\  const b = @max(a, x);
    //     \\}
    // );
}

// =============================================================================

const CountVisitor = struct {
    nodes_visited: u32 = 0,
    depth: u32 = 0,
    kinds_seen: std.AutoHashMapUnmanaged(Node.Tag, u32) = .{},
    tags: []const Node.Tag,
    allocator: Allocator = t.allocator,

    pub const Error = Allocator.Error;
    pub fn enterNode(self: *CountVisitor, node: Node.Index) Error!void {
        self.depth += 1;
        self.nodes_visited += 1;
        const tag = self.tags[node];
        const existing = self.kinds_seen.get(tag) orelse 0;
        try self.kinds_seen.put(self.allocator, tag, existing + 1);
    }

    pub fn exitNode(self: *CountVisitor, _: Node.Index) void {
        expect(self.depth > 0) catch @panic("expect failed");
        self.depth -= 1;
    }
    fn deinit(self: *CountVisitor) void {
        self.kinds_seen.deinit(self.allocator);
    }
};

fn testNodeCount(src: [:0]const u8, expected: u32, expected_tag_counts: anytype) !void {
    const allocator = std.testing.allocator;

    var ast = try Ast.parse(allocator, src, .zig);
    defer ast.deinit(allocator);
    var visitor: CountVisitor = .{ .tags = ast.nodes.items(.tag) };
    defer visitor.deinit();
    var walker = try Walker(CountVisitor, CountVisitor.Error).init(std.testing.allocator, &ast, &visitor);
    defer walker.deinit();

    try walker.walk();
    try std.testing.expectEqual(expected, visitor.nodes_visited);
    try std.testing.expectEqual(0, visitor.depth);

    for (expected_tag_counts) |e| {
        const tag: Node.Tag = e[0];
        const expected_tag_count: u32 = e[1];
        const actual = visitor.kinds_seen.get(tag) orelse 0;
        expectEqual(expected_tag_count, actual) catch |err| {
            std.debug.print(
                "Expected {d} nodes of type {s}, but found {d}",
                .{ expected_tag_count, @tagName(tag), actual },
            );
            return err;
        };
    }
}

test "node counts" {
    try testNodeCount("const x = 1;", 2, .{});
    try testNodeCount("const x: u32 = 1;", 3, .{});
    try testNodeCount(
        \\fn foo() Foo {
        \\  return Foo{ .a = 1, .b = 2 };
        \\}
    ,
        9,
        .{},
    );
    // try testNodeCount(1,
    // "const "
    // )
}
