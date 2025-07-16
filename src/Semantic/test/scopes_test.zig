const std = @import("std");
const Semantic = @import("../../Semantic.zig");

const t = std.testing;
const build = @import("./util.zig").build;

const Scope = Semantic.Scope;

test "functions create a parameter list + function body scope" {
    const source =
        \\fn add(x: i32, y: i32) i32 {
        \\  return x + y;
        \\}
    ;
    var sem = try build(source);
    defer sem.deinit();
    const scopes = sem.scopes.scopes;

    const root: Scope = scopes.get(0);
    try t.expectEqual(Semantic.ROOT_NODE_ID, root.node);
    try t.expectEqual(Semantic.ROOT_SCOPE_ID, root.id);
    try t.expectEqual(2, sem.scopes.getBindings(root.id).len); // `add` + implicit file-level container

    // root scope only has one child: the function declaration
    var children = &sem.scopes.children.items[0];
    try t.expectEqual(1, children.items.len);

    // check the function declaration. This scope contains the parameter list
    const fn_decl: Scope = scopes.get(children.items[0].int());
    try t.expectEqual(root.id.int() + 1, fn_decl.id.int());
    try t.expectEqual(fn_decl.flags, Scope.Flags{ .s_function = true });
    try t.expectEqual(root.id, fn_decl.parent.unwrap());

    // it has two parameters: x and y
    {
        const bindings = sem.scopes.getBindings(fn_decl.id);
        try t.expectEqual(2, bindings.len);

        const x = sem.symbols.get(bindings[0]);
        try t.expectEqualStrings("x", x.name);
        try t.expectEqual(fn_decl.id, x.scope);

        const y = sem.symbols.get(bindings[1]);
        try t.expectEqualStrings("y", y.name);
        try t.expectEqual(fn_decl.id, y.scope);
    }

    // next child is the function body
    children = &sem.scopes.children.items[fn_decl.id.int()];
    try t.expectEqual(1, children.items.len);
    const fn_body: Scope = scopes.get(children.items[0].int());
    try t.expectEqual(fn_decl.id.int() + 1, fn_body.id.int());
    try t.expectEqual(fn_decl.id.int(), fn_body.parent.unwrap().?.int());
    try t.expectEqual(fn_body.flags, Scope.Flags{ .s_function = true, .s_block = true });

    // this is the last one
    children = &sem.scopes.children.items[fn_body.id.int()];
    try t.expectEqual(0, children.items.len);
    try t.expectEqual(3, scopes.len); // root + decl + body
}
