const std = @import("std");
const semantic = @import("../../semantic.zig");

const t = std.testing;
const panic = std.debug.panic;
const print = std.debug.print;
const build = @import("./util.zig").build;
const Tuple = std.meta.Tuple;

const Scope = semantic.Scope;
const Symbol = semantic.Symbol;

const TestCase = Tuple(&[_]type{ [:0]const u8, Scope.Flags });

/// Check flags of the scope where a variable `x` is declared.
fn testXDeclScope(cases: []const TestCase) !void {
    for (cases) |case| {
        const source, const expected_flags = case;
        var sem = try build(source);
        defer sem.deinit();

        const x: Symbol.Id = brk: {
            if (sem.symbols.getSymbolNamed("x")) |_x| {
                break :brk _x;
            } else {
                print("Symbol 'x' not found in source:\n\n{s}\n\n", .{source});
                return error.TestFailed;
            }
        };

        // Flags for the scope `x` is declared in
        const scope: Scope.Id = sem.symbols.symbols.items(.scope)[x.int()];
        const flags: Scope.Flags = sem.scopes.scopes.items(.flags)[scope.int()];

        t.expectEqual(expected_flags, flags) catch |e| {
            print("Expected: {any}\nActual:   {any}\n\n", .{ expected_flags, flags });
            print("Source:\n\n{s}\n\n", .{source});
            return e;
        };
    }
}

/// Check flags of the scope where `x` is first referenced
fn testXRefScope(cases: []const TestCase) !void {
    for (cases) |case| {
        const source, const expected_flags = case;
        var sem = try build(source);
        defer sem.deinit();

        const x: Symbol.Id = brk: {
            if (sem.symbols.getSymbolNamed("x")) |_x| {
                break :brk _x;
            } else {
                print("Symbol 'x' not found in source:\n\n{s}\n\n", .{source});
                return error.TestFailed;
            }
        };

        const refs = sem.symbols.getReferences(x);
        t.expectEqual(1, refs.len) catch |e| {
            print("Expected 1 reference to 'x', got {d}\n\n", .{refs.len});
            print("Source:\n\n{s}\n\n", .{source});
            return e;
        };

        const scope: Scope.Id = sem.symbols.getReference(refs[0]).scope;
        const flags: Scope.Flags = sem.scopes.scopes.items(.flags)[scope.int()];

        t.expectEqual(expected_flags, flags) catch |e| {
            print("Expected: {any}\nActual:   {any}\n\n", .{ expected_flags, flags });
            print("Source:\n\n{s}\n\n", .{source});
            return e;
        };
    }
}

test "top-level" {
    // TODO: Should this be considered comptime?
    const cases = &[_]TestCase{.{ "const x = 1;", Scope.Flags{ .s_top = true } }};
    try testXDeclScope(cases);
}

test "function signatures and body scopes" {
    const cases = &[_]TestCase{
        // function symbols aren't declared in the scopes they create
        .{ "fn x() void {}", Scope.Flags{ .s_top = true } },
        // signatures create their own scope (params + return type)
        .{ "fn foo(x: u32) void { _ = x; }", Scope.Flags{ .s_function = true } },
        // bodies are flagged as blocks
        .{ "fn foo() void { const x = 1; _ = x; }", Scope.Flags{ .s_function = true, .s_block = true } },
    };
    try testXDeclScope(cases);

    const ref_cases = &[_]TestCase{
        // signatures create their own scope (params + return type)
        .{ "fn foo(x: type) x { @panic(\"not implemented\"); }", Scope.Flags{ .s_function = true } },
        .{ "fn foo(x: type) Foo(x) { @panic(\"not implemented\"); }", Scope.Flags{ .s_function = true } },
        .{ "fn foo(x: type, bar: x) void { _ = bar; }", Scope.Flags{ .s_function = true } },
        .{ "fn foo(x: type, bar: Foo(x)) void { _ = bar; }", Scope.Flags{ .s_function = true } },
    };
    try testXRefScope(ref_cases);
}

// test "function scopes are comptime if any of their parameters are comptime" {
//     const cases = &[_]TestCase{
//         .{ "fn foo(y: type) void { const x = 1; _ = x; }", Scope.Flags{ .s_function = true, .s_comptime = true } },
//         .{ "fn foo(comptime y: u32) void { const x = 1; _ = x; }", Scope.Flags{ .s_function = true, .s_comptime = true } },
//     };
//     try testXDeclScope(cases);
// }

test "comptime scopes" {
    const cases = &[_]TestCase{
        .{
            "const y = { const x = 1; };",
            Scope.Flags{ .s_block = true, .s_comptime = true },
        },
    };

    try testXDeclScope(cases);
}
