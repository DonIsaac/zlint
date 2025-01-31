const std = @import("std");

const Ast = std.zig.Ast;
const Node = Ast.Node;

const Walker = @import("./walk.zig").Walker;
const WalkState = @import("./walk.zig").WalkState;

const t = std.testing;

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
