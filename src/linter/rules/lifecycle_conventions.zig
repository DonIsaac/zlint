//! ## What This Rule Does
//! Enforces conventions for constructors (`init`) and destructors (`deinit`):
//!
//! 1. Destructors never fail, so they must not return an error union.
//! 2. Destructors taking `self: *T` invalidate it with `self.* = undefined;`.
//!    In safe builds this fills `self` with `0xaa` bytes, so using it after
//!    `deinit` crashes instead of silently working. In unsafe builds it
//!    compiles to nothing.
//! 3. `init` returns a value (`T` or `!T`). Constructors that return a pointer
//!    to their own type (`*T`, `!*T`, `?*T`) are named `create` and freed with
//!    `destroy`.
//! 4. A parameterless `init` that returns a constant (literals, enum literals,
//!    and references to constants) is a declaration instead:
//!    `pub const init: T = .{ ... };`. Callers can then write `.init`.
//!
//! These are not reported:
//! - destructors whose `self` is a value, `*anyopaque`, or a pointer to an
//!   `opaque` type
//! - destructors that free `self` (e.g. `allocator.destroy(self)`)
//! - `init` functions that initialize in place (`self: *T`), return `*const T`,
//!   or return a singleton (`return &instance;`)
//! - constant `init` functions used as function values (e.g. `callback(Foo.init)`)
//! - anything declared inside a `test` block
//!
//! Destructors that delegate to a helper method (e.g. `self.discard()`) are not
//! followed into it.
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
//!
//! const Qux = struct {
//!   x: u32,
//!   // returns a pointer, so it should be named `create`
//!   pub fn init(allocator: std.mem.Allocator) !*Qux {
//!     const self = try allocator.create(Qux);
//!     self.* = .{ .x = 0 };
//!     return self;
//!   }
//! };
//!
//! const Quux = struct {
//!   x: u32,
//!   // should be `pub const init: Quux = .{ .x = 0 };`
//!   pub fn init() Quux {
//!     return .{ .x = 0 };
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
//!
//! const Qux = struct {
//!   x: u32,
//!   pub fn create(allocator: std.mem.Allocator) !*Qux {
//!     const self = try allocator.create(Qux);
//!     self.* = .{ .x = 0 };
//!     return self;
//!   }
//! };
//!
//! const Quux = struct {
//!   x: u32,
//!   pub const init: Quux = .{ .x = 0 };
//! };
//! ```
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
/// Report `init` functions that return a pointer to their own type.
require_create_for_pointer_init: bool = true,

pub const meta: Rule.Meta = .{
    .name = "lifecycle-conventions",
    .category = .pedantic,
    // Individual fixes downgrade themselves to safe where possible.
    .fix = .dangerous_fix,
};

fn fallibleDestructorDiagnostic(ctx: *LinterContext, decl: Node.Index, return_type: Node.Index) Error {
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
        .not_invalidated => Cow.fmt(ctx.gpa, "Add `{s}.* = undefined;` at the end of the destructor", .{name}),
    } catch @panic("OOM");
    return e;
}

pub fn runOnSymbol(self: *const LifecycleConventions, symbol: Symbol.Id, ctx: *LinterContext) void {
    const id = symbol.into(usize);
    const symbols = ctx.symbols().symbols.slice();
    const flags: Symbol.Flags = symbols.items(.flags)[id];
    if (!flags.s_fn or flags.s_extern) return;

    const decl: Node.Index = symbols.items(.decl)[id];
    const name: []const u8 = symbols.items(.name)[id];
    if (std.mem.eql(u8, name, "init")) {
        const container = lifecycleContainer(ctx, symbol, decl) orelse return;
        return self.checkInit(ctx, symbol, decl, container);
    }
    for (self.deinitializers) |deinit_name| {
        if (std.mem.eql(u8, name, deinit_name)) {
            _ = lifecycleContainer(ctx, symbol, decl) orelse return;
            return self.checkDeinit(ctx, symbol, decl);
        }
    }
}

/// Get the container scope a constructor or destructor belongs to, or `null`
/// if it should not be checked.
fn lifecycleContainer(ctx: *const LinterContext, symbol: Symbol.Id, decl: Node.Index) ?Scope.Id {
    if (ctx.ast().nodeTag(decl) != .fn_decl) {
        @branchHint(.unlikely);
        return null;
    }

    // `opaque {}` scopes have no container flags
    const scopes = ctx.scopes();
    const scope_flags: []const Scope.Flags = scopes.scopes.items(.flags);
    const fn_scope = ctx.symbols().symbols.items(.scope)[symbol.int()];
    const container = scope_flags[fn_scope.int()];
    if (!container.isContainer() and !container.s_top) return null;
    var parents = scopes.iterParents(fn_scope);
    while (parents.next()) |scope| {
        if (scope_flags[scope.int()].s_test) return null;
    }
    return fn_scope;
}

fn checkDeinit(self: *const LifecycleConventions, ctx: *LinterContext, symbol: Symbol.Id, decl: Node.Index) void {
    const ast = ctx.ast();
    var buf: [1]Node.Index = undefined;
    const f = ast.fullFnProto(&buf, decl).?;

    var fallible = false;
    if (f.ast.return_type.unwrap()) |return_type| {
        if (ast_utils.hasErrorUnion(ast, return_type)) {
            fallible = true;
            ctx.report(fallibleDestructorDiagnostic(ctx, decl, return_type));
        }
    }

    var params = f.iterate(ast);
    const first_param = params.next() orelse {
        // TODO(@DonIsaac): report `deinit` fns with no params?
        @branchHint(.unlikely);
        return;
    };
    const self_type = first_param.type_expr orelse return;
    const self_ptr = ast.fullPtrType(self_type) orelse return;
    if (self_ptr.size != .one) return;

    // e.g. vtable thunks
    const pointee = self_ptr.ast.child_type;
    if (ast.nodeTag(pointee) == .identifier and mainTokenIs(ctx, pointee, "anyopaque")) return;

    const name_token = first_param.name_token orelse return;
    // external callers may keep reading `self`
    const external = ctx.symbols().symbols.items(.flags)[symbol.int()].s_export or
        f.ast.callconv_expr != .none;

    if (self_ptr.const_token) |const_token| {
        if (!self.require_mutable_self) return;
        const diagnostic = constSelfDiagnostic(ctx, name_token, self_type);
        // the pointer type looks deliberately chosen
        const can_fix = !external and
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
    // `try` skips the end of the body, and `volatile` writes are observable
    const can_fix = !external and !fallible and self_ptr.volatile_token == null;
    const fix: ?fixers.Destructor = if (can_fix) .{ .decl = decl, .self_symbol = self_symbol, .self_token = name_token } else null;
    self.checkDeinitClearsSelf(ctx, self_symbol, name_token, fix);
}

fn checkDeinitClearsSelf(
    self: *const LifecycleConventions,
    ctx: *LinterContext,
    self_symbol: Symbol.Id,
    self_token: TokenIndex,
    fix: ?fixers.Destructor,
) void {
    const ast = ctx.ast();
    const links = ctx.links();
    var defect: ?Defect = null;
    var resets_field = false;
    var refs = ctx.symbols().iterReferences(self_symbol);

    while (refs.next()) |ref| {
        const parent = links.getParent(ref.node) orelse continue;
        switch (ast.nodeTag(parent)) {
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
                resets_field = isSentinelValue(ctx, ast.nodeData(assign).node_and_node[1]);
            },
            // `allocator.destroy(self)`
            .call_one, .call_one_comma, .call, .call_comma => {
                if (isDestroyCall(ctx, parent, ref.node)) return;
            },
            else => continue,
        }
    }

    if (defect == null and resets_field) return;
    const d = defect orelse .not_invalidated;
    const diagnostic = defectiveDeinitDiagnostic(ctx, d, self_token);
    switch (d) {
        .missing_deref => |assign| ctx.reportWithFix(assign, diagnostic, &fixers.addDeref),
        .not_invalidated => if (fix) |destructor| ctx.reportWithFix(destructor, diagnostic, &fixers.invalidateSelf) else ctx.report(diagnostic),
        .not_undefined => ctx.report(diagnostic),
    }
}

fn checkInit(self: *const LifecycleConventions, ctx: *LinterContext, symbol: Symbol.Id, decl: Node.Index, container: Scope.Id) void {
    const ast = ctx.ast();
    var buf: [1]Node.Index = undefined;
    const f = ast.fullFnProto(&buf, decl).?;
    if (f.ast.callconv_expr != .none or ctx.symbols().symbols.items(.flags)[symbol.int()].s_export) return;
    const return_type = f.ast.return_type.unwrap() orelse return;
    const body = ast.nodeData(decl).node_and_node[1];

    var params = f.iterate(ast);
    const first_param = params.next();

    // `fn init(...) !?*Self`
    var payload = return_type;
    while (true) switch (ast.nodeTag(payload)) {
        .error_union => payload = ast.nodeData(payload).node_and_node[1],
        .optional_type => payload = ast.nodeData(payload).node,
        else => break,
    };
    if (selfPointer(ctx, container, payload)) |ptr| {
        if (!self.require_create_for_pointer_init) return;
        // `*const Self` is not an owned allocation
        if (ptr.const_token != null) return;
        // `fn init(self: *Self) *Self` initializes in place
        if (first_param) |param| {
            if (param.type_expr) |ty| if (selfPointer(ctx, container, ty) != null) return;
        }
        // singletons, e.g. `return &instance;`
        if (findReturn(ast, decl, .address_of)) return;
        return ctx.report(pointerInitDiagnostic(ctx, return_type));
    }

    // `fn init() Self { return <constant>; }`
    if (first_param != null or ast_utils.hasErrorUnion(ast, return_type)) return;
    if (!isSelfType(ctx, container, return_type)) return;
    var stmt_buf: [2]Node.Index = undefined;
    const stmts = ast.blockStatements(&stmt_buf, body) orelse return;
    if (stmts.len != 1 or ast.nodeTag(stmts[0]) != .@"return") return;
    const value = ast.nodeData(stmts[0]).opt_node.unwrap() orelse return;
    if (isConstantExpr(ctx, value) and !isInitUsedAsValue(ctx, symbol, container)) {
        ctx.report(constantInitDiagnostic(ctx, f, return_type));
    }
}

/// Whether `fn_decl`'s body has a `return`, optionally only those whose
/// operand has the tag `operand`.
fn findReturn(ast: *const Ast, fn_decl: Node.Index, operand: ?Node.Tag) bool {
    // The parser reserves `fn_decl` before parsing the body, and adds blocks
    // after their statements, so the body's subtree is `(fn_decl, body]`.
    const start = @backingInt(fn_decl) + 1;
    const end = @backingInt(ast.nodeData(fn_decl).node_and_node[1]) + 1;
    for (ast.nodes.items(.tag)[start..end], start..) |tag, i| {
        if (tag != .@"return") continue;
        const expected = operand orelse return true;
        const value = ast.nodeData(@fromBackingInt(@intCast(i))).opt_node.unwrap() orelse continue;
        if (ast.nodeTag(value) == expected) return true;
    }
    return false;
}

/// `node(...)`
fn isCallee(ast: *const Ast, call: Node.Index, node: Node.Index) bool {
    var buf: [1]Node.Index = undefined;
    const full = ast.fullCall(&buf, call) orelse return false;
    return full.ast.fn_expr == node;
}

/// Whether `init` is used without being called, e.g. as a callback.
fn isInitUsedAsValue(ctx: *LinterContext, symbol: Symbol.Id, container: Scope.Id) bool {
    var refs = ctx.symbols().iterReferences(symbol);
    while (refs.next()) |ref| {
        if (!ref.flags.call) return true;
    }

    // `Self.init`. Member accesses are not linked to the symbol they access.
    const ast = ctx.ast();
    const links = ctx.links();
    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .field_access) continue;
        const node: Node.Index = @fromBackingInt(@intCast(i));
        const lhs, const field = ast.nodeData(node).node_and_token;
        if (!std.mem.eql(u8, ctx.semantic.tokenSlice(field), "init")) continue;
        if (links.getParent(node)) |parent| if (isCallee(ast, parent, node)) continue;
        if (isSelfType(ctx, container, lhs)) return true;
    }
    return false;
}

fn pointerInitDiagnostic(ctx: *LinterContext, return_type: Node.Index) Error {
    var e = ctx.diagnostic(
        "Constructors that return a pointer should be named `create`, not `init`",
        .{ctx.labelN(return_type, "`init` returns a pointer to its own type", .{})},
    );
    e.help = Cow.static("Rename it to `create`, and free it with `destroy`");
    return e;
}

fn constantInitDiagnostic(ctx: *LinterContext, f: Ast.full.FnProto, return_type: Node.Index) Error {
    var e = ctx.diagnostic(
        "`init` takes no parameters and returns a constant",
        .{ctx.labelT(f.name_token.?, "This can be a declaration", .{})},
    );
    e.help = Cow.fmt(
        ctx.gpa,
        "Replace it with `{s}const init: {s} = ...;` so callers can use `.init`",
        .{ if (f.visib_token != null) "pub " else "", ctx.semantic.nodeSpan(return_type).snippet(ctx.semantic.source()) },
    ) catch @panic("OOM");
    return e;
}

/// `*Self`, where `Self` is the type `container` declares.
fn selfPointer(ctx: *LinterContext, container: Scope.Id, node: Node.Index) ?Ast.full.PtrType {
    const ptr = ctx.ast().fullPtrType(node) orelse return null;
    return if (ptr.size == .one and isSelfType(ctx, container, ptr.ast.child_type)) ptr else null;
}

/// `@This()`, the name `container` is bound to, or an alias of either.
fn isSelfType(ctx: *LinterContext, container: Scope.Id, node: Node.Index) bool {
    const ast = ctx.ast();
    var target = node;
    // bounded to break alias cycles
    for (0..8) |_| {
        if (ast.nodeTag(target) != .identifier) break;
        target = ast_utils.resolveConstAlias(ctx, target) orelse return false;
    }
    const scopes = ctx.scopes();
    if (target == scopes.scopes.items(.node)[container.int()]) return true;
    if (!ast_utils.isThisCall(ctx, target)) return false;

    // `@This()` refers to the innermost container it appears in
    const flags: []const Scope.Flags = scopes.scopes.items(.flags);
    var parents = scopes.iterParents(ctx.links().scopes.items[@backingInt(target)]);
    while (parents.next()) |scope| {
        const scope_flags = flags[scope.int()];
        if (scope_flags.isContainer() or scope_flags.s_top) return scope == container;
    }
    return false;
}

/// Whether `node` is known at comptime without evaluating any calls.
fn isConstantExpr(ctx: *const LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    switch (ast.nodeTag(node)) {
        .number_literal,
        .char_literal,
        .string_literal,
        .multiline_string_literal,
        .enum_literal,
        => return true,
        .negation => return isConstantExpr(ctx, ast.nodeData(node).node),
        .grouped_expression => return isConstantExpr(ctx, ast.nodeData(node).node_and_token[0]),
        .identifier => return isConstantIdentifier(ctx, node),
        else => {},
    }

    var buf: [2]Node.Index = undefined;
    const values = if (ast.fullStructInit(&buf, node)) |init|
        init.ast.fields
    else if (ast.fullArrayInit(&buf, node)) |init|
        init.ast.elements
    else
        return false;
    for (values) |value| {
        if (!isConstantExpr(ctx, value)) return false;
    }
    return true;
}

fn isConstantIdentifier(ctx: *const LinterContext, node: Node.Index) bool {
    const token = ctx.ast().nodeMainToken(node);
    const name = ctx.semantic.tokenSlice(token);
    inline for (.{ "true", "false", "null", "undefined" }) |literal| {
        if (std.mem.eql(u8, name, literal)) return true;
    }
    const scope = ctx.links().scopes.items[@backingInt(node)];
    const symbol = ctx.semantic.resolveBinding(scope, name, .decls) orelse return false;
    const flags: Symbol.Flags = ctx.symbols().symbols.items(.flags)[symbol.int()];
    return flags.s_const or flags.s_fn;
}

/// `lhs = ...`
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

fn mainTokenIs(ctx: *const LinterContext, node: Node.Index, text: []const u8) bool {
    return std.mem.eql(u8, ctx.semantic.tokenSlice(ctx.ast().nodeMainToken(node)), text);
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
fn isSentinelValue(ctx: *const LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    return switch (ast.nodeTag(node)) {
        .identifier => mainTokenIs(ctx, node, "null") or mainTokenIs(ctx, node, "false"),
        .number_literal => mainTokenIs(ctx, node, "0"),
        .negation => blk: {
            const operand = ast.nodeData(node).node;
            break :blk ast.nodeTag(operand) == .number_literal and mainTokenIs(ctx, operand, "1");
        },
        else => false,
    };
}

/// `<expr>.destroy(arg)`
fn isDestroyCall(ctx: *const LinterContext, call: Node.Index, arg: Node.Index) bool {
    const ast = ctx.ast();
    var buf: [1]Node.Index = undefined;
    const full = ast.fullCall(&buf, call) orelse return false;
    if (full.ast.params.len != 1 or full.ast.params[0] != arg) return false;
    const callee = full.ast.fn_expr;
    if (ast.nodeTag(callee) != .field_access) return false;
    const field_name = ast.nodeData(callee).node_and_token[1];
    return std.mem.eql(u8, ctx.semantic.tokenSlice(field_name), "destroy");
}

const fixers = struct {
    /// `self = undefined` -> `self.* = undefined`
    ///
    /// Safe: assigning to a parameter does not compile.
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

    pub const Destructor = struct {
        decl: Node.Index,
        self_symbol: Symbol.Id,
        self_token: TokenIndex,
    };

    /// Append `self.* = undefined;` to a destructor.
    ///
    /// Dangerous: callers that read `self` after `deinit` now read garbage.
    fn invalidateSelf(destructor: Destructor, builder: Fix.Builder) !Fix {
        const ctx = builder.ctx;
        const last = finalStatement(ctx, destructor.decl) orelse return builder.noop();
        if (!isOnlyAccessed(ctx, destructor.self_symbol)) return builder.noop();
        const line = lineAfter(ctx, last) orelse return builder.noop();
        return builder.replacef(
            .new(line.start, line.start),
            "{s}{s}.* = undefined;{s}",
            .{ line.indent, ctx.semantic.tokenSlice(destructor.self_token), line.eol },
        );
    }

    /// The last statement of `fn_decl`, if it always runs last.
    fn finalStatement(ctx: *const LinterContext, fn_decl: Node.Index) ?Node.Index {
        const ast = ctx.ast();
        if (findReturn(ast, fn_decl, null)) return null;

        var buf: [2]Node.Index = undefined;
        const stmts = ast.blockStatements(&buf, ast.nodeData(fn_decl).node_and_node[1]) orelse return null;
        if (stmts.len == 0) return null;
        for (stmts) |stmt| {
            if (ast.nodeTag(stmt) == .@"defer") return null;
        }
        const last = stmts[stmts.len - 1];
        return if (isNoreturn(ctx, last)) null else last;
    }

    /// Whether `self` is only used to reach its fields. Rejects uses that may
    /// free it (`self.release()`, `pool.release(self)`), suggest it is reused
    /// (`self.x = null`), or discard it (`_ = self`).
    fn isOnlyAccessed(ctx: *const LinterContext, self_symbol: Symbol.Id) bool {
        const ast = ctx.ast();
        const links = ctx.links();
        var refs = ctx.symbols().iterReferences(self_symbol);
        while (refs.next()) |ref| {
            const parent = links.getParent(ref.node) orelse return false;
            switch (ast.nodeTag(parent)) {
                .deref => {},
                .field_access => {
                    const use = links.getParent(parent) orelse continue;
                    if (isCallee(ast, use, parent)) return false;
                    const assign = assignmentTo(ast, links, parent) orelse continue;
                    const value = ast.nodeData(assign).node_and_node[1];
                    if (isSentinelValue(ctx, value) or isResetValue(ast, value)) return false;
                },
                else => return false,
            }
        }
        return true;
    }

    const Line = struct {
        start: u32,
        indent: []const u8,
        eol: []const u8,
    };

    /// The line after `stmt`, indented like it. `null` if `stmt` shares a line
    /// with other code.
    fn lineAfter(ctx: *const LinterContext, stmt: Node.Index) ?Line {
        const source = ctx.ast().source;
        const span = ctx.semantic.nodeSpan(stmt);

        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..span.start], '\n')) |i| i + 1 else 0;
        const indent = source[line_start..span.start];
        if (std.mem.indexOfNone(u8, indent, " \t") != null) return null;

        const newline = std.mem.indexOfScalarPos(u8, source, span.end, '\n') orelse return null;
        // only a `;` and a comment may follow `stmt`
        var rest = std.mem.trim(u8, source[span.end..newline], " \t\r");
        if (std.mem.startsWith(u8, rest, ";")) rest = std.mem.trimStart(u8, rest[1..], " \t");
        if (rest.len > 0 and !std.mem.startsWith(u8, rest, "//")) return null;

        return .{
            .start = @intCast(newline + 1),
            .indent = indent,
            .eol = if (newline > 0 and source[newline - 1] == '\r') "\r\n" else "\n",
        };
    }

    /// `unreachable`, `@panic(...)`, or `@trap()`
    fn isNoreturn(ctx: *const LinterContext, node: Node.Index) bool {
        const ast = ctx.ast();
        return switch (ast.nodeTag(node)) {
            .unreachable_literal => true,
            .builtin_call_two, .builtin_call_two_comma => blk: {
                const name = ctx.semantic.tokenSlice(ast.nodeMainToken(node));
                break :blk std.mem.eql(u8, name, "@panic") or std.mem.eql(u8, name, "@trap");
            },
            else => false,
        };
    }

    /// `self: *const T` -> `self: *T`
    ///
    /// Dangerous: callers passing a `*const T` stop compiling.
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

/// A fix case where no fix should be applied.
fn noFix(comptime src: [:0]const u8) RuleTester.FixCase {
    return .{ .src = src, .expected = src, .fails_lint = true };
}

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
        // constructors returning values
        \\const Foo = struct {
        \\  list: std.ArrayList(u8),
        \\  pub fn init(allocator: std.mem.Allocator) !Foo {
        \\    return .{ .list = try .initCapacity(allocator, 8) };
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn create(allocator: std.mem.Allocator) !*Foo {
        \\    const self = try allocator.create(Foo);
        \\    self.* = .{ .x = 0 };
        \\    return self;
        \\  }
        \\};
        ,
        // in-place initialization
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn init(self: *Foo, x: u32) !void {
        \\    self.* = .{ .x = x };
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  x: u32,
        \\  const Self = @This();
        \\  pub fn init(self: *Self) *Self {
        \\    self.* = .{ .x = 0 };
        \\    return self;
        \\  }
        \\};
        ,
        // returns a pointer to some other type
        \\const Decompress = union(enum) {
        \\  none: *Reader,
        \\  pub fn init(d: *Decompress, r: *Reader) *Reader {
        \\    d.* = .{ .none = r };
        \\    return r;
        \\  }
        \\};
        ,
        \\const Outer = struct {
        \\  const Self = @This();
        \\  const Inner = struct {
        \\    pub fn init(allocator: std.mem.Allocator) !*Self {
        \\      return allocator.create(Self);
        \\    }
        \\  };
        \\};
        ,
        "const Foo = struct { pub fn init(allocator: std.mem.Allocator) ![]Foo { return allocator.alloc(Foo, 1); } };",
        "const Foo = struct { extern fn init() *Foo; };",
        // parameterless constructors that are not constant
        "const Foo = struct { x: u32, pub fn init() Foo { return initWithOptions(.{}); } };",
        "const Foo = struct { x: u32, pub fn init() Foo { const x = 1; return .{ .x = x }; } };",
        "const Foo = struct { x: u32, pub fn init() !Foo { return .{ .x = 0 }; } };",
        "const Foo = struct { x: u32, pub fn init() u32 { return 0; } };",
        // used as a function value
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn init() Foo {
        \\    return .{ .x = 0 };
        \\  }
        \\  pub const constructor = bridge.constructor(Foo.init, .{});
        \\};
        ,
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn init() Foo {
        \\    return .{ .x = 0 };
        \\  }
        \\  const vtable = .{ .create = init };
        \\};
        ,
        // fields may be runtime values
        \\const Other = struct { pub var counter: u32 = 0; };
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn init() Foo {
        \\    return .{ .x = Other.counter };
        \\  }
        \\};
        ,
        // not an owned allocation
        \\const Foo = struct {
        \\  x: u32,
        \\  const default: Foo = .{ .x = 0 };
        \\  pub fn init() *const Foo {
        \\    return &default;
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  x: u32,
        \\  var instance: Foo = .{ .x = 0 };
        \\  pub fn init() *Foo {
        \\    if (instance.x == 0) instance.x = 1;
        \\    return &instance;
        \\  }
        \\};
        ,
        \\var counter: u32 = 0;
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn init() Foo {
        \\    return .{ .x = counter };
        \\  }
        \\};
        ,
        \\const Foo = opaque {
        \\  pub fn init() *Foo {
        \\    return c.foo_new();
        \\  }
        \\};
        ,
        // test-only helpers
        \\test "foo" {
        \\  const Foo = struct {
        \\    x: u32,
        \\    pub fn init() Foo {
        \\      return .{ .x = 0 };
        \\    }
        \\  };
        \\  _ = Foo;
        \\}
        ,
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
        // constructors returning a pointer to their own type
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn init(allocator: std.mem.Allocator) !*Foo {
        \\    const self = try allocator.create(Foo);
        \\    self.* = .{ .x = 0 };
        \\    return self;
        \\  }
        \\};
        ,
        "const Foo = struct { pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*@This() { return allocator.create(@This()); } };",
        \\const Foo = struct {
        \\  const Self = @This();
        \\  pub fn init(allocator: std.mem.Allocator) !*Self {
        \\    return allocator.create(Self);
        \\  }
        \\};
        ,
        // file-level struct
        \\const Self = @This();
        \\x: u32,
        \\pub fn init(allocator: std.mem.Allocator) !*Self {
        \\  return allocator.create(Self);
        \\}
        ,
        // parameterless constructors returning a constant
        "const Foo = struct { x: u32, pub fn init() Foo { return .{ .x = 0 }; } };",
        "const Foo = struct { x: u32, fn init() @This() { return .{ .x = 0 }; } };",
        "const Foo = enum { a, b, pub fn init() Foo { return .a; } };",
        // calls and decl literals are not function values
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn init() Foo {
        \\    return .{ .x = 0 };
        \\  }
        \\};
        \\var foo = Foo.init();
        \\var bar: Bar = .init;
        ,
        \\const default_x = 1;
        \\const Foo = struct {
        \\  x: i32,
        \\  inner: struct { name: []const u8, ok: bool },
        \\  list: [2]u8,
        \\  pub fn init() Foo {
        \\    return .{ .x = -default_x, .inner = .{ .name = "foo", .ok = true }, .list = .{ 'a', 2 } };
        \\  }
        \\};
        ,
        // comptime parameters are constants
        \\fn Fnv(comptime offset: u64) type {
        \\  return struct {
        \\    const Self = @This();
        \\    value: u64,
        \\    pub fn init() Self {
        \\      return Self{ .value = offset };
        \\    }
        \\  };
        \\}
        ,
        // unrelated `.init` accesses do not suppress the report
        \\const Foo = struct {
        \\  x: u32,
        \\  pub fn init() Foo {
        \\    return .{ .x = 0 };
        \\  }
        \\};
        \\var gpa = std.heap.DebugAllocator(.{}).init;
        \\const Bar = struct { init: bool };
        \\fn isInit(b: Bar) bool { return b.init; }
        ,
        // optional pointers
        "const Foo = struct { pub fn init(allocator: std.mem.Allocator) ?*Foo { return allocator.create(Foo) catch null; } };",
        "const Foo = struct { pub fn init(allocator: std.mem.Allocator) !?*Foo { return try allocator.create(Foo); } };",
        // alias chains
        \\const Foo = struct {
        \\  const Self = Foo;
        \\  const This = Self;
        \\  pub fn init(allocator: std.mem.Allocator) !*This {
        \\    return allocator.create(This);
        \\  }
        \\};
        ,
    };

    const fix = comptime &[_]RuleTester.FixCase{
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
        noFix("fn deinit(self: *Foo) void { self = other; }"),
        .{
            .src =
            \\const Foo = struct {
            \\    list: List,
            \\    pub fn deinit(self: *Foo, gpa: Allocator) void {
            \\        self.list.deinit(gpa);
            \\    }
            \\};
            ,
            .expected =
            \\const Foo = struct {
            \\    list: List,
            \\    pub fn deinit(self: *Foo, gpa: Allocator) void {
            \\        self.list.deinit(gpa);
            \\        self.* = undefined;
            \\    }
            \\};
            ,
            .kind = .fix,
        },
        .{
            .src =
            \\fn deinit(this: *Foo) void {
            \\  if (this.a) |a| {
            \\    a.deinit(); // trailing
            \\  }
            \\}
            ,
            .expected =
            \\fn deinit(this: *Foo) void {
            \\  if (this.a) |a| {
            \\    a.deinit(); // trailing
            \\  }
            \\  this.* = undefined;
            \\}
            ,
            .kind = .fix,
        },
        .{
            .src =
            \\fn deinit(self: *Foo) void {
            \\    {
            \\        defer self.b.deinit();
            \\        self.a.deinit();
            \\    }
            \\}
            ,
            .expected =
            \\fn deinit(self: *Foo) void {
            \\    {
            \\        defer self.b.deinit();
            \\        self.a.deinit();
            \\    }
            \\    self.* = undefined;
            \\}
            ,
            .kind = .fix,
        },
        // deferred code runs afterwards
        noFix(
            \\fn deinit(self: *Foo) void {
            \\    defer self.mutex.unlock();
            \\    self.a.deinit();
            \\}
        ),
        // early returns skip the end
        noFix(
            \\fn deinit(self: *Foo) void {
            \\    const a = self.a orelse return;
            \\    a.deinit();
            \\}
        ),
        // `self` may be freed
        noFix(
            \\fn deinit(self: *Foo) void {
            \\    self.pool.release(self);
            \\}
        ),
        noFix(
            \\fn deinit(self: *Foo) void {
            \\    self.release();
            \\}
        ),
        // `self` looks reusable
        noFix(
            \\fn deinit(self: *Foo) void {
            \\    self.a.deinit();
            \\    self.a = null;
            \\}
        ),
        // would become a pointless discard
        noFix(
            \\fn deinit(self: *Foo) void {
            \\    _ = self;
            \\}
        ),
        // would be unreachable
        noFix(
            \\fn deinit(self: *Foo) void {
            \\    self.a.deinit();
            \\    unreachable;
            \\}
        ),
        noFix(
            \\fn deinit(self: *Foo) void {
            \\    self.a.deinit();
            \\    @panic("oops");
            \\}
        ),
        // one-line bodies
        noFix("fn deinit(self: *Foo) void { self.a.deinit(); }"),
        noFix(
            \\fn deinit(self: *Foo) void {
            \\    self.a.deinit(); }
        ),
        // signature is fixed by external callers
        noFix(
            \\export fn deinit(self: *Foo) void {
            \\    self.a.deinit();
            \\}
        ),
        noFix(
            \\fn deinit(self: *Foo) callconv(.c) void {
            \\    self.a.deinit();
            \\}
        ),
        // `try` skips the end of the body
        noFix(
            \\fn deinit(self: *Foo) !void {
            \\    try self.a.deinit();
            \\}
        ),
        // memory-mapped registers
        noFix(
            \\fn deinit(self: *volatile Foo) void {
            \\    self.a.deinit();
            \\}
        ),
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

    const fix = comptime &[_]RuleTester.FixCase{
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
        noFix("export fn deinit(self: *const Foo) void { _ = self; }"),
        noFix("fn deinit(self: *const Foo) callconv(.c) void { _ = self; }"),
        // pointer type looks deliberately chosen
        noFix("fn deinit(self: *allowzero const Foo) void { _ = self; }"),
        noFix("fn deinit(self: *const volatile Foo) void { _ = self; }"),
        noFix("fn deinit(self: *align(8) const Foo) void { _ = self; }"),
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

test "LifecycleConventions without require_create_for_pointer_init" {
    const t = std.testing;

    var lifecycle_conventions = LifecycleConventions{ .require_create_for_pointer_init = false };
    var runner = RuleTester.init(t.allocator, lifecycle_conventions.rule());
    runner.snapshot_name = "lifecycle-conventions-no-pointer-init";
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "const Foo = struct { pub fn init(allocator: std.mem.Allocator) !*Foo { return allocator.create(Foo); } };",
    };

    const fail = &[_][:0]const u8{
        "const Foo = struct { x: u32, pub fn init() Foo { return .{ .x = 0 }; } };",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
