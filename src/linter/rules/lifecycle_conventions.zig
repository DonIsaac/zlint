//! ## What This Rule Does
//! Enforces conventions for destructors (functions named `deinit`):
//!
//! 1. Destructors should never fail. They must not return an error union.
//! 2. Destructors taking `self: *T` should invalidate `self` by assigning
//!    `undefined` to it (`self.* = undefined;`).
//!
//! In safe build modes, assigning `undefined` fills memory with `0xaa` bytes.
//! Any use of the value after it has been deinitialized then reads garbage and
//! is far more likely to crash or trip a safety check than to silently "work".
//! In unsafe build modes the assignment compiles to nothing, so it has no
//! runtime cost.
//!
//! Destructors are skipped when invalidating `self` is impossible or harmful:
//! - `self` is taken by value, or is a pointer to `anyopaque` or an `opaque` type
//! - `self` is freed inside the destructor (e.g. `allocator.destroy(self)`).
//!   Writing to it afterwards would be a use-after-free.
//! - the destructor is declared inside a `test` block
//!
//! Destructors that delegate to a helper method (e.g. `self.discard()`) are
//! not followed into that helper and will still be reported.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const Foo = struct {
//!   list: std.ArrayList(u32),
//!   // fallible destructor
//!   pub fn deinit(self: *Foo, allocator: std.mem.Allocator) !void {
//!     self.list.deinit(allocator);
//!     self.* = undefined;
//!   }
//! };
//!
//! const Bar = struct {
//!   list: std.ArrayList(u32),
//!   // `self` is never invalidated
//!   pub fn deinit(self: *Bar, allocator: std.mem.Allocator) void {
//!     self.list.deinit(allocator);
//!   }
//! };
//!
//! const Baz = struct {
//!   x: u32,
//!   // resets `self` instead of invalidating it
//!   pub fn deinit(self: *Baz) void {
//!     self.* = .{ .x = 0 };
//!   }
//! };
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const Foo = struct {
//!   list: std.ArrayList(u32),
//!   pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
//!     self.list.deinit(allocator);
//!     self.* = undefined;
//!   }
//! };
//!
//! const Bar = struct {
//!   allocator: std.mem.Allocator,
//!   // `self` is freed, so it cannot be invalidated
//!   pub fn deinit(self: *Bar) void {
//!     self.allocator.destroy(self);
//!   }
//! };
//! ```
//!
//! ## Configuration
//! - `deinitializers` - names of functions treated as destructors. Defaults to `["deinit"]`.
//! - `allow_reset` - accept destructors that reset `self` instead of
//!   invalidating it, which makes them safe to call more than once. This
//!   includes `self.* = .{}`, `self.* = .empty` (or any other decl literal),
//!   and setting a field to `null`, `false`, `0`, or `-1`. Defaults to `false`.
//! - `require_mutable_self` - report destructors that take `self: *const T`,
//!   since they cannot invalidate `self`. Defaults to `false`, as `*const T`
//!   destructors are a common, deliberate choice for small value types.

const std = @import("std");
const util = @import("util");
const ast_utils = @import("../ast_utils.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = @import("../rule.zig").Rule;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Symbol = Semantic.Symbol;
const Scope = Semantic.Scope;

const Error = @import("../../Error.zig");
const Fix = @import("../fix.zig").Fix;
const Cow = util.Cow(false);

// Rule metadata
const LifecycleConventions = @This();

/// Names of functions treated as destructors.
deinitializers: []const []const u8 = &.{"deinit"},
/// Accept destructors that reset `self` (`self.* = .{}`, `self.* = .empty`,
/// `self.fd = -1`, ...) instead of invalidating it with `undefined`.
allow_reset: bool = false,
/// Report destructors that take `self: *const T`.
require_mutable_self: bool = false,

pub const meta: Rule.Meta = .{
    .name = "lifecycle-conventions",
    .category = .pedantic,
    // Individual fixes downgrade themselves to safe where possible.
    .fix = .dangerous_fix,
};

fn fallableDestructorDiagnostic(ctx: *LinterContext, decl: Node.Index, return_type: Node.Index) Error {
    return ctx.diagnostic(
        "Destructors should never fail",
        .{
            ctx.labelN(decl, "Destructor is declared here", .{}),
            ctx.labelN(return_type, "It may not return error unions", .{}),
        },
    );
}

fn constSelfDiagnostic(ctx: *LinterContext, self_token: TokenIndex, self_type: Node.Index) Error {
    const name = ctx.semantic.tokenSlice(self_token);
    var e = ctx.diagnosticf(
        "Destructor takes `{s}` as a const pointer, so it cannot be invalidated",
        .{name},
        .{ctx.labelN(self_type, "`{s}` points to constant memory", .{name})},
    );
    e.help = Cow.fmt(ctx.gpa, "Take `{s}` as a mutable pointer", .{name}) catch @panic("OOM");
    return e;
}

const Defect = union(enum) {
    /// `self = undefined;`
    missing_deref: Node.Index,
    /// `self.* = not_undefined_literal;`
    not_undefined: Node.Index,
    /// no `self.* = undefined;` anywhere
    not_invalidated,
};

fn defectiveDeinitDiagnostic(ctx: *LinterContext, defect: Defect, self_token: TokenIndex) Error {
    const name = ctx.semantic.tokenSlice(self_token);
    var e: Error = switch (defect) {
        .missing_deref => |assign| ctx.diagnosticf(
            "Destructor assigns to the `{s}` pointer instead of the value it points to",
            .{name},
            .{ctx.labelN(assign, "This only overwrites the local pointer", .{})},
        ),
        .not_undefined => |assign| ctx.diagnosticf(
            "Destructor should invalidate `{s}` with `undefined`",
            .{name},
            .{ctx.labelN(assign, "`{s}` is assigned a value other than `undefined` here", .{name})},
        ),
        .not_invalidated => ctx.diagnosticf(
            "Destructor does not invalidate `{s}`",
            .{name},
            .{ctx.spanT(self_token)},
        ),
    };
    e.help = switch (defect) {
        .missing_deref => Cow.fmt(ctx.gpa, "Dereference `{s}` to invalidate the memory it points to", .{name}),
        .not_undefined => Cow.static("Assign `undefined` instead"),
        .not_invalidated => Cow.fmt(ctx.gpa, "Add `{s}.* = undefined;` at the end of the destructor.", .{name}),
    } catch @panic("OOM");
    return e;
}

pub fn runOnSymbol(self: *const LifecycleConventions, symbol: Symbol.Id, ctx: *LinterContext) void {
    const id = symbol.into(usize);
    const symbols = ctx.symbols().symbols.slice();
    const flags: Symbol.Flags = symbols.items(.flags)[id];
    if (!flags.s_fn or flags.s_extern) return;

    const decls: []const Ast.Node.Index = symbols.items(.decl);
    const name: []const u8 = symbols.items(.name)[id];
    for (self.deinitializers) |deinit_name| {
        if (std.mem.eql(u8, name, deinit_name)) return self.checkDeinit(ctx, symbol, decls[id]);
    }
}

fn checkDeinit(self: *const LifecycleConventions, ctx: *LinterContext, symbol: Symbol.Id, decl: Ast.Node.Index) void {
    const ast = ctx.ast();
    const node_tags: []const Ast.Node.Tag = ast.nodes.items(.tag);
    if (node_tags[@backingInt(decl)] != .fn_decl) {
        @branchHint(.unlikely);
        return;
    }

    // fn decls are always bound in a container scope. Containers without
    // container flags are `opaque {}`, whose values cannot be dereferenced.
    const scopes = ctx.scopes();
    const scope_flags: []const Scope.Flags = scopes.scopes.items(.flags);
    const fn_scope = ctx.symbols().symbols.items(.scope)[symbol.int()];
    {
        const container = scope_flags[fn_scope.int()];
        if (!container.isContainer() and !container.s_top) return;
        var parents = scopes.iterParents(fn_scope);
        while (parents.next()) |scope| {
            if (scope_flags[scope.int()].s_test) return;
        }
    }

    var buf: [1]Ast.Node.Index = undefined;
    const f = ast.fullFnProto(&buf, decl).?;

    // check for `fn deinit(self: *Self) !void`
    if (f.ast.return_type.unwrap()) |return_type| {
        if (ast_utils.hasErrorUnion(ast, return_type)) {
            ctx.report(fallableDestructorDiagnostic(ctx, decl, return_type));
        }
    }

    var params = f.iterate(ast);
    const first_param = params.next() orelse {
        // TODO(@DonIsaac): report `deinit` fns with no params?
        @branchHint(.unlikely);
        return;
    };
    // Only `self: *T` can be invalidated with `self.* = undefined`.
    const self_type = first_param.type_expr orelse return;
    const self_ptr = ast.fullPtrType(self_type) orelse return;
    if (self_ptr.size != .one) return;

    // `*anyopaque` destructors (e.g. vtable thunks) cannot be dereferenced
    if (isIdentifier(ast, self_ptr.ast.child_type, "anyopaque")) return;

    // fn decls always have named params
    const name_token = first_param.name_token orelse return;

    if (self_ptr.const_token) |const_token| {
        if (!self.require_mutable_self) return;
        const diagnostic = constSelfDiagnostic(ctx, name_token, self_type);
        // Removing `const` changes the signature. Do not offer it when the
        // signature is fixed by external callers or the pointer type looks
        // deliberately chosen.
        const can_fix = !ctx.symbols().symbols.items(.flags)[symbol.int()].s_export and
            f.ast.callconv_expr == .none and
            self_ptr.allowzero_token == null and
            self_ptr.volatile_token == null and
            self_ptr.ast.align_node == .none and
            self_ptr.ast.addrspace_node == .none;
        if (can_fix) {
            ctx.reportWithFix(const_token, diagnostic, &fixers.removeConst);
        } else {
            ctx.report(diagnostic);
        }
        return;
    }

    const self_symbol: Symbol.Id = ctx.links().symbols.get(name_token) orelse {
        util.debugAssert(false, "found a fn param node with no linked symbol. This is a bug in semantic analysis.", .{});
        return;
    };
    self.checkDeinitClearsSelf(ctx, self_symbol, name_token, node_tags);
}

fn checkDeinitClearsSelf(
    self: *const LifecycleConventions,
    ctx: *LinterContext,
    self_symbol: Symbol.Id,
    self_token: TokenIndex,
    node_tags: []const Node.Tag,
) void {
    const ast = ctx.ast();
    const links = ctx.links();
    var defect: ?Defect = null;
    var resets_field = false;
    var refs = ctx.symbols().iterReferences(self_symbol);

    while (refs.next()) |ref| {
        const parent = links.getParent(ref.node) orelse continue;
        switch (node_tags[@backingInt(parent)]) {
            // `self = y`
            .assign => {
                if (ast.nodeData(parent).node_and_node[0] != ref.node) continue;
                if (defect == null) defect = .{ .missing_deref = parent };
            },
            // `self.* = y`
            .deref => {
                const assign = assignmentTo(ast, links, parent) orelse continue;
                const rhs = ast.nodeData(assign).node_and_node[1];
                if (isUndefined(ctx, rhs)) return;
                if (self.allow_reset and isResetValue(ast, rhs)) return;
                if (defect == null) defect = .{ .not_undefined = assign };
            },
            // `self.field = y`
            .field_access => {
                if (!self.allow_reset or resets_field) continue;
                const assign = assignmentTo(ast, links, parent) orelse continue;
                resets_field = isSentinelValue(ast, ast.nodeData(assign).node_and_node[1]);
            },
            // `allocator.destroy(self)`. Writing to `self` afterwards would be
            // a use-after-free.
            .call_one, .call_one_comma, .call, .call_comma => {
                if (isDestroyCall(ast, parent, ref.node)) return;
            },
            else => continue,
        }
    }

    if (defect == null and resets_field) return;
    const d = defect orelse .not_invalidated;
    const diagnostic = defectiveDeinitDiagnostic(ctx, d, self_token);
    switch (d) {
        .missing_deref => |assign| ctx.reportWithFix(assign, diagnostic, &fixers.addDeref),
        else => ctx.report(diagnostic),
    }
}

/// Get the `=` assignment whose left-hand side is exactly `lhs`.
fn assignmentTo(ast: *const Ast, links: *const Semantic.NodeLinks, lhs: Node.Index) ?Node.Index {
    const assign = links.getParent(lhs) orelse return null;
    if (ast.nodeTag(assign) != .assign) return null;
    if (ast.nodeData(assign).node_and_node[0] != lhs) return null;
    return assign;
}

fn isUndefined(ctx: *const LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    return ast.nodeTag(node) == .identifier and ast_utils.isUndefinedLiteral(ctx, ast.nodeMainToken(node));
}

fn isIdentifier(ast: *const Ast, node: Node.Index, name: []const u8) bool {
    return ast.nodeTag(node) == .identifier and mainTokenIs(ast, node, name);
}

fn mainTokenIs(ast: *const Ast, node: Node.Index, text: []const u8) bool {
    return std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), text);
}

/// `.{}`, or a decl literal like `.empty` or `.init`
fn isResetValue(ast: *const Ast, node: Node.Index) bool {
    return switch (ast.nodeTag(node)) {
        .enum_literal => true,
        .struct_init_dot_two => blk: {
            const a, const b = ast.nodeData(node).opt_node_and_opt_node;
            break :blk a == .none and b == .none;
        },
        else => false,
    };
}

/// `null`, `false`, `0`, or `-1`
fn isSentinelValue(ast: *const Ast, node: Node.Index) bool {
    return switch (ast.nodeTag(node)) {
        .identifier => mainTokenIs(ast, node, "null") or mainTokenIs(ast, node, "false"),
        .number_literal => mainTokenIs(ast, node, "0"),
        .negation => blk: {
            const operand = ast.nodeData(node).node;
            break :blk ast.nodeTag(operand) == .number_literal and mainTokenIs(ast, operand, "1");
        },
        else => false,
    };
}

/// `<expr>.destroy(arg)`
fn isDestroyCall(ast: *const Ast, call: Node.Index, arg: Node.Index) bool {
    var buf: [1]Node.Index = undefined;
    const full = ast.fullCall(&buf, call) orelse return false;
    if (full.ast.params.len != 1 or full.ast.params[0] != arg) return false;
    const callee = full.ast.fn_expr;
    if (ast.nodeTag(callee) != .field_access) return false;
    const field_name = ast.nodeData(callee).node_and_token[1];
    return std.mem.eql(u8, ast.tokenSlice(field_name), "destroy");
}

const fixers = struct {
    /// `self = undefined` -> `self.* = undefined`
    ///
    /// Safe: assigning to a parameter is a compile error, so the original code
    /// has no behavior to preserve.
    fn addDeref(assign: Node.Index, builder: Fix.Builder) !Fix {
        const ast = builder.ctx.ast();
        const lhs, const rhs = ast.nodeData(assign).node_and_node;
        if (!isUndefined(builder.ctx, rhs)) return builder.noop();

        var fix = builder.replacef(
            builder.spanCovering(.node, @backingInt(lhs)),
            "{s}.*",
            .{builder.snippet(.node, @backingInt(lhs))},
        );
        fix.meta.dangerous = false;
        return fix;
    }

    /// `self: *const T` -> `self: *T`
    ///
    /// Dangerous: callers holding a `const` value or a `*const T` stop compiling.
    fn removeConst(const_token: TokenIndex, builder: Fix.Builder) !Fix {
        const sema = builder.ctx.semantic;
        // also remove the whitespace between `const` and the pointee
        const start = sema.tokenSpan(const_token).start;
        const end = sema.tokenSpan(const_token + 1).start;
        return builder.delete(.new(start, end));
    }
};

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *LifecycleConventions) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test LifecycleConventions {
    const t = std.testing;

    var lifecycle_conventions = LifecycleConventions{};
    var runner = RuleTester.init(t.allocator, lifecycle_conventions.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "const x = 1;",
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn deinit(self: *Foo) void {
        \\    self.* = undefined;
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  list: std.ArrayList(u8),
        \\  pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
        \\    self.list.deinit(allocator);
        \\    self.* = undefined;
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  list: std.ArrayList(u8),
        \\  pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
        \\    defer self.* = undefined;
        \\    self.list.deinit(allocator);
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn deinit(this: *Foo) void {
        \\    this.* = undefined;
        \\  }
        \\};
        ,
        // not a destructor
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn reset(self: *Foo) void {
        \\    self.x = 0;
        \\  }
        \\};
        ,
        "extern fn deinit(ptr: *anyopaque) void;",
        // opaque pointers cannot be dereferenced
        "fn deinit(ptr: *anyopaque) void { _ = ptr; }",
        "fn deinit(ptr: *const anyopaque) void { _ = ptr; }",
        \\const Foo = opaque {
        \\  pub fn deinit(self: *Foo) void {
        \\    c.foo_free(@ptrCast(self));
        \\  }
        \\};
        ,
        // field writes are not invalidations
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn deinit(self: *Foo) void {
        \\    self.x = 0;
        \\    self.* = undefined;
        \\  }
        \\};
        ,
        // value receivers cannot be invalidated
        \\const Foo = struct {
        \\  buf: []u8,
        \\  allocator: std.mem.Allocator,
        \\  pub fn deinit(self: Foo) void {
        \\    self.allocator.free(self.buf);
        \\  }
        \\};
        ,
        // const receivers are only reported with `require_mutable_self`
        \\const Foo = struct {
        \\  buf: []u8,
        \\  pub fn deinit(self: *const Foo, allocator: std.mem.Allocator) void {
        \\    allocator.free(self.buf);
        \\  }
        \\};
        ,
        // `self` is freed, so writing to it would be a use-after-free
        \\const Foo = struct {
        \\  allocator: std.mem.Allocator,
        \\  pub fn deinit(self: *Foo) void {
        \\    self.allocator.destroy(self);
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
        \\    allocator.destroy(self);
        \\  }
        \\};
        ,
        // test-only helpers
        \\test "foo" {
        \\  const Foo = struct {
        \\    x: u32,
        \\    pub fn deinit(self: *Foo) void {
        \\      _ = self;
        \\    }
        \\  };
        \\  _ = Foo;
        \\}
        ,
    };

    const fail = &[_][:0]const u8{
        // fallible destructor
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn deinit(self: *Foo) !void {
        \\    self.* = undefined;
        \\  }
        \\};
        ,
        // assigns to the pointer, not the pointee
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn deinit(self: *Foo) void {
        \\    self = undefined;
        \\  }
        \\};
        ,
        // invalidated with something other than `undefined`
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn deinit(self: *Foo) void {
        \\    self.* = .{ .x = 0 };
        \\  }
        \\};
        ,
        // never invalidated
        \\const Foo = struct {
        \\  list: std.ArrayList(u8),
        \\  pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
        \\    self.list.deinit(allocator);
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn deinit(self: *Foo) void {
        \\    _ = self;
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn deinit(this: *Foo) void {
        \\    this = undefined;
        \\  }
        \\};
        ,
        // reported once, not once per write
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn deinit(self: *Foo) void {
        \\    self.* = .{ .x = 0 };
        \\    self.* = .{ .x = 1 };
        \\  }
        \\};
        ,
        // resets are only allowed with `allow_reset`
        \\const Foo = struct {
        \\  x: u32 = 0,
        \\  pub fn deinit(self: *Foo) void {
        \\    self.* = .{};
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  fd: i32,
        \\  pub fn deinit(self: *Foo) void {
        \\    close(self.fd);
        \\    self.fd = -1;
        \\  }
        \\};
        ,
        // not a call to `destroy`
        \\const Foo = struct {
        \\  pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
        \\    allocator.free(self);
        \\  }
        \\};
        ,
    };

    const fix = &[_]RuleTester.FixCase{
        .{
            .src = "fn deinit(self: *Foo) void { self = undefined; }",
            .expected = "fn deinit(self: *Foo) void { self.* = undefined; }",
            .kind = .fix,
        },
        .{
            .src = "fn deinit(this: *Foo) void { this = undefined; }",
            .expected = "fn deinit(this: *Foo) void { this.* = undefined; }",
            .kind = .fix,
        },
        // intent is unclear when the rhs is not `undefined`
        .{
            .src = "fn deinit(self: *Foo) void { self = other; }",
            .expected = "fn deinit(self: *Foo) void { self = other; }",
            .fails_lint = true,
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}

test "LifecycleConventions with require_mutable_self" {
    const t = std.testing;

    var lifecycle_conventions = LifecycleConventions{ .require_mutable_self = true };
    var runner = RuleTester.init(t.allocator, lifecycle_conventions.rule());
    runner.snapshot_name = "lifecycle-conventions-require-mutable-self";
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "fn deinit(self: *Foo) void { self.* = undefined; }",
        "fn deinit(ptr: *const anyopaque) void { _ = ptr; }",
        // not a single-item pointer
        "fn deinit(self: []const Foo) void { _ = self; }",
    };

    const fail = &[_][:0]const u8{
        \\const Foo = struct {
        \\  buf: []u8,
        \\  pub fn deinit(self: *const Foo, allocator: std.mem.Allocator) void {
        \\    allocator.free(self.buf);
        \\  }
        \\};
        ,
    };

    const fix = &[_]RuleTester.FixCase{
        .{
            .src = "fn deinit(self: *const Foo) void { _ = self; }",
            .expected = "fn deinit(self: *Foo) void { _ = self; }",
            .kind = .fix,
        },
        .{
            .src = "fn deinit(self: *const Foo) void { self.* = undefined; }",
            .expected = "fn deinit(self: *Foo) void { self.* = undefined; }",
            .kind = .fix,
        },
        // signature is fixed by external callers
        .{
            .src = "export fn deinit(self: *const Foo) void { _ = self; }",
            .expected = "export fn deinit(self: *const Foo) void { _ = self; }",
            .fails_lint = true,
        },
        .{
            .src = "fn deinit(self: *const Foo) callconv(.c) void { _ = self; }",
            .expected = "fn deinit(self: *const Foo) callconv(.c) void { _ = self; }",
            .fails_lint = true,
        },
        // pointer type looks deliberately chosen
        .{
            .src = "fn deinit(self: *allowzero const Foo) void { _ = self; }",
            .expected = "fn deinit(self: *allowzero const Foo) void { _ = self; }",
            .fails_lint = true,
        },
        .{
            .src = "fn deinit(self: *const volatile Foo) void { _ = self; }",
            .expected = "fn deinit(self: *const volatile Foo) void { _ = self; }",
            .fails_lint = true,
        },
        .{
            .src = "fn deinit(self: *align(8) const Foo) void { _ = self; }",
            .expected = "fn deinit(self: *align(8) const Foo) void { _ = self; }",
            .fails_lint = true,
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}

test "LifecycleConventions with allow_reset" {
    const t = std.testing;

    var lifecycle_conventions = LifecycleConventions{ .allow_reset = true };
    var runner = RuleTester.init(t.allocator, lifecycle_conventions.rule());
    runner.snapshot_name = "lifecycle-conventions-allow-reset";
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "fn deinit(self: *Foo) void { self.* = undefined; }",
        "fn deinit(self: *Foo) void { self.* = .{}; }",
        "fn deinit(self: *Foo) void { self.* = .empty; }",
        "fn deinit(self: *Foo) void { self.* = .init; }",
        "fn deinit(self: *Foo) void { if (self.db) |db| { close(db); self.db = null; } }",
        "fn deinit(self: *Foo) void { close(self.fd); self.fd = -1; }",
        "fn deinit(self: *Foo) void { self.len = 0; }",
        "fn deinit(self: *Foo) void { self.open = false; }",
    };

    const fail = &[_][:0]const u8{
        // explicit values are not a reset to empty
        "fn deinit(self: *Foo) void { self.* = .{ .x = 0 }; }",
        "fn deinit(self: *Foo) void { self.* = Foo.init(); }",
        // not sentinel values
        "fn deinit(self: *Foo) void { self.fd = 5; }",
        "fn deinit(self: *Foo) void { self.fd = -2; }",
        "fn deinit(self: *Foo) void { self.inner.fd = -1; }",
        // a later reset does not excuse a bad invalidation
        "fn deinit(self: *Foo) void { self.* = .{ .x = 1 }; self.fd = -1; }",
        "fn deinit(self: *Foo) void { _ = self; }",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
