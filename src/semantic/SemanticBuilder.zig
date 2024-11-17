// Important things I've learned about Zig's AST:
//
// For nodes:
// - tags .foo and .foo_semicolon are the same.
// - if there's a .foo and .foo_two tag, then
//   - .foo_two has actual ast nodes in `data.lhs` and `data.rhs`
//   - .foo's lhs/rhs are actually a span that should be used to range-index
//     `ast.extra_data`. That gets the variable-len list of child nodes.
//

_gpa: Allocator,
_arena: ArenaAllocator,
_curr_scope_id: Semantic.Scope.Id = ROOT_SCOPE,
_curr_symbol_id: ?Semantic.Symbol.Id = null,
_curr_scope_flags: Scope.Flags = .{},

// stacks

_scope_stack: std.ArrayListUnmanaged(Semantic.Scope.Id) = .{},
/// When entering an initialization container for a symbol, that symbol's ID
/// is pushed here. This lets us record members and exports.
_symbol_stack: std.ArrayListUnmanaged(Semantic.Symbol.Id) = .{},
_node_stack: std.ArrayListUnmanaged(NodeIndex) = .{},

/// SAFETY: initialized after parsing. Same safety rationale as _root_scope.
_semantic: Semantic = undefined,
/// Errors encountered during parsing and analysis.
///
/// Errors in this list are allocated using this list's allocator.
_errors: std.ArrayListUnmanaged(Error) = .{},

/// The root node always has an index of 0. Since it is never referenced by other nodes,
/// the Zig team uses it to represent `null` without wasting extra memory.
const NULL_NODE: NodeIndex = Semantic.NULL_NODE;
const ROOT_SCOPE: Semantic.Scope.Id = Semantic.ROOT_SCOPE_ID;

pub const Result = Error.Result(Semantic);
pub const SemanticError = error{
    ParseFailed,
    /// Expected `ast.fullFoo` to return `Some(foo)` but it returned `None`,
    FullMismatch,
    /// Expected an identifier name, but none was found.
    MissingIdentifier,
} || Allocator.Error;

pub fn init(gpa: Allocator) SemanticBuilder {
    return .{
        ._gpa = gpa,
        ._arena = ArenaAllocator.init(gpa),
    };
}

/// Parse and analyze a Zig source file.
///
/// Analysis consists of:
/// - Binding symbols to a symbol table
/// - Scope analysis
///
/// Parse and analysis errors are collected in the returned `Result`. An
/// error union variant is only ever returned for fatal errors, such as (but not limited to):
/// - Allocation failures (e.g. out of memory)
/// - Unexpected nulls
/// - Out-of-bounds access
///
/// In some  cases, SemanticBuilder may choose to panic instead of
/// returning an error union. These assertions produce better release
/// binaries and catch bugs earlier.
pub fn build(builder: *SemanticBuilder, source: stringSlice) SemanticError!Result {
    // var builder = SemanticBuilder{ ._gpa = gpa, ._arena = ArenaAllocator.init(gpa) };
    // defer builder.deinit();
    // NOTE: ast is moved
    const gpa = builder._gpa;
    const ast = try builder.parse(source);
    const node_links = try NodeLinks.init(gpa, &ast);
    assert(ast.nodes.len == node_links.parents.items.len);
    assert(ast.nodes.len == node_links.scopes.items.len);

    // reserve capacity for stacks
    try builder._scope_stack.ensureTotalCapacity(gpa, 8); // TODO: use stack fallback allocator?
    try builder._symbol_stack.ensureTotalCapacity(gpa, 8);
    // TODO: verify this hypothesis. What is the max node stack len while
    // building? (avg over a representative sample of real Zig files.)
    try builder._node_stack.ensureTotalCapacity(gpa, @max(ast.nodes.len, 32) >> 2);

    builder._semantic = Semantic{
        .ast = ast,
        .node_links = node_links,
        ._arena = builder._arena,
        ._gpa = gpa,
    };
    errdefer builder._semantic.deinit();

    // Create root scope & symbol and push them onto their stacks. Also
    // pushes the root node. None of these are ever popped.
    try builder.enterRoot();
    builder.assertRoot(); // sanity check

    for (builder._semantic.ast.rootDecls()) |node| {
        builder.visitNode(node) catch |e| return e;
        builder.assertRoot();
    }

    return Result.new(builder._gpa, builder._semantic, builder._errors);
}

/// Deinitialize build-specific resources. Errors and the constructed
/// `Semantic` instance are left untouched.
pub fn deinit(self: *SemanticBuilder) void {
    self._scope_stack.deinit(self._gpa);
    self._symbol_stack.deinit(self._gpa);
    self._node_stack.deinit(self._gpa);
}

fn parse(self: *SemanticBuilder, source: stringSlice) !Ast {
    const ast = try Ast.parse(self._arena.allocator(), source, .zig);

    // Record parse errors
    if (ast.errors.len > 0) {
        try self._errors.ensureUnusedCapacity(self._gpa, ast.errors.len);
        for (ast.errors) |ast_err| {
            // Not an error. TODO: verify this assumption
            if (ast_err.is_note) continue;
            self.addAstError(&ast, ast_err) catch @panic("Out of memory");
        }
    }

    return ast;
}

// =========================================================================
// ================================= VISIT =================================
// =========================================================================

/// Visit an AST node.
///
/// Null and bounds checks are performed here, while actual logic is
/// handled by `visitNode`. This lets us inline checks within caller
/// functions, reducing unnecessary branching and stack pointer pushes.
inline fn visit(self: *SemanticBuilder, node_id: NodeIndex) SemanticError!void {
    // when lhs/rhs are 0 (root node), it means `null`
    if (node_id == NULL_NODE) return;
    // Seeing this happen a log, needs debugging.
    if (node_id >= self.AST().nodes.len) {
        // TODO: hint to compiler that this branch is unlikely. @branchHint
        // is documented in the Zig language reference, but does not appear available in v0.13.0.
        // https://ziglang.org/documentation/master/#branchHint
        // @branchHint(.unlikely);
        //
        // print("ERROR: node ID out of bounds ({d})\n", .{node_id});
        return;
    }

    return self.visitNode(node_id);
}

/// Visit a node in the AST. Do not call this directly, use `visit` instead.
fn visitNode(self: *SemanticBuilder, node_id: NodeIndex) SemanticError!void {
    assert(node_id > 0 and node_id < self.AST().nodes.len);

    const ast = self.AST();
    const tag: Ast.Node.Tag = ast.nodes.items(.tag)[node_id];
    const data: []Node.Data = ast.nodes.items(.data);

    try self.enterNode(node_id);
    defer self.exitNode();

    // TODO:
    // - bind function declarations
    // - record symbol types and signatures
    // - record symbol references
    // - Scope flags for unions, structs, and enums. Blocks are currently handled (TODO: that needs testing).
    // - Test the shit out of it
    switch (tag) {
        // root node is never referenced b/c of NULL_NODE check at function start
        .root => unreachable,
        // containers and container members
        // ```zig
        // const Foo = struct { // <-- visits struct/enum/union containers
        // };
        // ```
        .container_decl,
        .container_decl_arg,
        .container_decl_trailing,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        // tagged union
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => {
            var buf: [2]u32 = undefined;
            const container = ast.fullContainerDecl(&buf, node_id) orelse unreachable;
            return self.visitContainer(node_id, container);
        },
        .container_field, .container_field_align, .container_field_init => {
            const field = ast.fullContainerField(node_id) orelse unreachable;
            return self.visitContainerField(node_id, field);
        },
        .field_access, .unwrap_optional => return self.visit(data[node_id].lhs),
        // variable declarations
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            const decl = self.AST().fullVarDecl(node_id) orelse unreachable;
            return self.visitVarDecl(node_id, decl);
        },
        .assign_destructure => {
            const destructure = ast.assignDestructure(node_id);
            return self.visitAssignDestructure(node_id, destructure);
        },
        .array_init,
        .array_init_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        => {
            var buf: [2]NodeIndex = undefined;
            const arr = ast.fullArrayInit(&buf, node_id) orelse unreachable;
            return self.visitArrayInit(node_id, arr);
        },
        .struct_init,
        .struct_init_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init_one,
        .struct_init_one_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        => {
            var buf: [2]NodeIndex = undefined;
            const struct_init = ast.fullStructInit(&buf, node_id) orelse unreachable;
            return self.visitStructInit(node_id, struct_init);
        },
        // function-related nodes

        // function declarations
        .fn_decl,
        => return self.visitFnDecl(node_id),
        .fn_proto, .fn_proto_one, .fn_proto_multi => {
            var buf: [1]NodeIndex = undefined;
            const fn_proto = ast.fullFnProto(&buf, node_id) orelse unreachable;
            return self.visitFnProto(node_id, fn_proto);
        },

        // function calls
        .call, .call_comma, .async_call, .async_call_comma => {
            // fullCall uses callFull under the hood. Skipping the
            // middleman removes a redundant tag check. This check guards
            // against future API changes made by the Zig team.
            if (IS_DEBUG) {
                var buf: [1]u32 = undefined;
                util.assert(ast.fullCall(&buf, node_id) != null, "fullCall returned null for tag {any}", .{tag});
            }
            const call = ast.callFull(node_id);
            return self.visitCall(node_id, call);
        },
        .call_one, .call_one_comma, .async_call_one, .async_call_one_comma => {
            var buf: [1]u32 = undefined;
            // fullCall uses callOne under the hood. Skipping the
            // middleman removes a redundant tag check. This check guards
            // against future API changes made by the Zig team.
            if (IS_DEBUG) {
                util.assert(ast.fullCall(&buf, node_id) != null, "fullCall returned null for tag {any}", .{tag});
            }
            const call = ast.callOne(&buf, node_id);
            return self.visitCall(node_id, call);
        },
        .builtin_call, .builtin_call_comma => return self.visitRecursiveSlice(node_id),

        // control flow

        // loops
        .while_simple, .@"while", .while_cont => {
            const while_stmt = ast.fullWhile(node_id) orelse unreachable;
            return self.visitWhile(node_id, while_stmt);
        },
        .for_simple => {
            const for_stmt = ast.forSimple(node_id);
            return self.visitFor(node_id, for_stmt);
        },
        .@"for" => {
            const for_stmt = ast.forFull(node_id);
            return self.visitFor(node_id, for_stmt);
        },

        // conditionals
        .@"if", .if_simple => {
            const if_stmt = ast.fullIf(node_id) orelse unreachable;
            return self.visitIf(node_id, if_stmt);
        },
        .@"switch", .switch_comma => {
            const condition = data[node_id].lhs;
            const extra = ast.extraData(data[node_id].rhs, Ast.Node.SubRange);
            const cases = ast.extra_data[extra.start..extra.end];
            return self.visitSwitch(node_id, condition, cases);
        },
        .switch_case, .switch_case_inline, .switch_case_one, .switch_case_inline_one => {
            const case = ast.fullSwitchCase(node_id) orelse unreachable;
            return self.visitSwitchCase(node_id, case);
        },

        .@"catch" => return self.visitCatch(node_id),

        // blocks
        .block_two, .block_two_semicolon => {
            const statements = [2]NodeIndex{ data[node_id].lhs, data[node_id].rhs };
            return if (statements[0] == NULL_NODE)
                self.visitBlock(statements[0..0])
            else if (statements[1] == NULL_NODE)
                self.visitBlock(statements[0..1])
            else
                self.visitBlock(statements[0..2]);
        },
        .block, .block_semicolon => return self.visitBlock(ast.extra_data[data[node_id].lhs..data[node_id].rhs]),

        .test_decl => return self.visit(data[node_id].rhs),

        // lhs/rhs for these nodes are always undefined
        .identifier,
        .char_literal,
        .number_literal,
        .unreachable_literal,
        .string_literal,
        // for these, it's always a token index
        .multiline_string_literal,
        => return,

        // TODO: record reference for rhs (.identifier)?
        // lhs is `.` token, rhs is `.identifier` token
        .error_value,
        // lhs is `.` token, main token is `.identifier`, rhs unused
        .enum_literal,
        => return,

        .@"asm", .asm_simple, .asm_output, .asm_input => return,

        .@"comptime" => {
            const prev_comptime = self.setScopeFlag("s_comptime", true);
            defer self.restoreScopeFlag("s_comptime", prev_comptime);

            return self.visit(data[node_id].lhs);
        },

        // lhs is undefined, rhs is a token index
        // see: Parse.zig, line 2934
        // TODO: visit block
        .error_set_decl => return,

        // lhs is a node, rhs is a token
        .grouped_expression,
        // lhs is a node, rhs is an index into Slice
        .slice,
        .slice_sentinel,
        => return self.visit(data[node_id].lhs),
        // lhs is a token, rhs is a node
        .@"break" => return self.visit(data[node_id].rhs),
        // rhs for these nodes are always `undefined`.
        .@"await",
        .@"continue",
        .@"nosuspend",
        .@"return",
        .@"suspend",
        .@"try",
        .@"usingnamespace",
        .@"resume",
        .address_of,
        .bit_not,
        .bool_not,
        .deref,
        .negation_wrap,
        .negation,
        .optional_type,
        => return self.visit(data[node_id].lhs),
        // lhs for these nodes is always `undefined`.
        .@"defer" => return self.visit(self.getNodeData(node_id).rhs),

        else => return self.visitRecursive(node_id),
    }
}

/// Basic lhs/rhs traversal. This is just a shorthand.
inline fn visitRecursive(self: *SemanticBuilder, node_id: NodeIndex) !void {
    const data: Node.Data = self.getNodeData(node_id);
    try self.visit(data.lhs);
    try self.visit(data.rhs);
}

inline fn visitRecursiveSlice(self: *SemanticBuilder, node_id: NodeIndex) !void {
    const data = self.getNodeData(node_id);
    const ast = self.AST();
    self.assertCtx(data.lhs < ast.extra_data.len, "slice start exceeds extra_data bounds", .{});
    self.assertCtx(data.rhs < ast.extra_data.len, "slice end exceeds extra_data bounds", .{});
    const children = ast.extra_data[data.lhs..data.rhs];
    for (children) |child| {
        try self.visit(child);
    }
}

// TODO: inline after we're done debugging
fn visitBlock(self: *SemanticBuilder, statements: []const NodeIndex) !void {
    const is_root = self.currentScope() == ROOT_SCOPE;
    const was_comptime = self._curr_scope_flags.s_comptime;
    if (is_root) {
        self._curr_scope_flags.s_comptime = true;
    }
    defer if (is_root) {
        self._curr_scope_flags.s_comptime = was_comptime;
    };

    try self.enterScope(.{ .s_block = true });
    defer self.exitScope();

    for (statements) |stmt| {
        try self.visit(stmt);
    }
}

fn visitContainer(self: *SemanticBuilder, _: NodeIndex, container: full.ContainerDecl) !void {
    try self.enterScope(.{ .s_block = true, .s_enum = container.ast.enum_token != null });
    defer self.exitScope();
    for (container.ast.members) |member| {
        try self.visit(member);
    }
}

/// Visit a container field (e.g. a struct property, enum variant, etc).
///
/// ```zig
/// const Foo = { // <-- Declared within this container's scope.
///   bar: u32    // <-- This is a container field. It is always Symbol.Visibility.public.
/// };            //     It is added to Foo's member table.
/// ```
fn visitContainerField(self: *SemanticBuilder, node_id: NodeIndex, field: full.ContainerField) !void {
    const main_token = self.AST().nodes.items(.main_token)[node_id];
    // main_token points to the field name
    // NOTE: container fields are always public
    // TODO: record type annotations
    _ = try self.declareMemberSymbol(.{
        .name = self.getIdentifier(main_token),
        .flags = .{
            .s_comptime = field.comptime_token != null,
        },
    });
    if (field.ast.value_expr != NULL_NODE) {
        try self.visit(field.ast.value_expr);
    }
}

/// Visit a variable declaration. Global declarations are visited
/// separately, because their lhs/rhs nodes and main token mean different
/// things.
fn visitVarDecl(self: *SemanticBuilder, node_id: NodeIndex, var_decl: full.VarDecl) !void {
    const node = self.getNode(node_id);
    // main_token points to `var`, `const` keyword. `.identifier` comes immediately afterwards
    const identifier: ?string = self.getIdentifier(node.main_token + 1);
    const debug_name: ?string = if (identifier == null) "<anonymous var decl>" else null;
    const visibility = if (var_decl.visib_token == null) Symbol.Visibility.private else Symbol.Visibility.public;
    const symbol_id = try self.bindSymbol(.{
        .name = identifier,
        .debug_name = debug_name,
        .visibility = visibility,
        .flags = .{ .s_comptime = var_decl.comptime_token != null },
    });
    try self.enterContainerSymbol(symbol_id);
    defer self.exitContainerSymbol();

    if (var_decl.ast.init_node != NULL_NODE) {
        assert(var_decl.ast.init_node < self.AST().nodes.len);
        try self.visit(var_decl.ast.init_node);
    }
}

fn visitAssignDestructure(self: *SemanticBuilder, _: NodeIndex, destructure: full.AssignDestructure) SemanticError!void {
    self.assertCtx(destructure.ast.variables.len > 0, "Invalid destructuring assignment: no variables are being declared.", .{});
    const ast = self.AST();
    const main_tokens: []TokenIndex = ast.nodes.items(.main_token);
    const token_tags: []Token.Tag = ast.tokens.items(.tag);
    const is_comptime = destructure.comptime_token != null;

    for (destructure.ast.variables) |var_id| {
        const main_token: TokenIndex = main_tokens[var_id];
        const decl: full.VarDecl = ast.fullVarDecl(var_id) orelse {
            return SemanticError.FullMismatch;
        };
        const identifier: ?string = self.getIdentifier(main_token + 1);
        util.assert(identifier != null, "assignment declarations are not valid when an identifier name is missing.", .{});
        // note: intentionally not using bindSymbol (for now, at least)
        _ = try self.declareSymbol(.{
            .declaration_node = var_id,
            .name = identifier,
            .visibility = if (decl.visib_token != null) .public else .private,
            .flags = .{
                .s_comptime = is_comptime,
                .s_const = token_tags[main_token] == .keyword_const,
            },
        });
    }
    try self.visit(destructure.ast.value_expr);
}

fn visitArrayInit(self: *SemanticBuilder, _: NodeIndex, arr: full.ArrayInit) !void {
    for (arr.ast.elements) |el| {
        try self.visit(el);
    }
}

fn visitStructInit(self: *SemanticBuilder, _: NodeIndex, @"struct": full.StructInit) !void {
    for (@"struct".ast.fields) |field| {
        try self.visit(field);
    }
}
// ============================== STATEMENTS ===============================

inline fn visitWhile(self: *SemanticBuilder, _: NodeIndex, while_stmt: full.While) !void {
    try self.visit(while_stmt.ast.cond_expr);
    try self.visit(while_stmt.ast.cont_expr); // what is this?
    try self.visit(while_stmt.ast.then_expr);
    try self.visit(while_stmt.ast.else_expr);
}

inline fn visitFor(self: *SemanticBuilder, _: NodeIndex, for_stmt: full.For) !void {
    for (for_stmt.ast.inputs) |input| {
        try self.visit(input);
    }
    try self.visit(for_stmt.ast.then_expr);
    try self.visit(for_stmt.ast.else_expr);
}

inline fn visitIf(self: *SemanticBuilder, _: NodeIndex, if_stmt: full.If) !void {
    try self.visit(if_stmt.ast.cond_expr);
    // HYPOTHESIS: these will contain blocks, which enter/exit a scope when
    // visited. Thus we can/should skip that here.
    try self.visit(if_stmt.ast.then_expr);
    try self.visit(if_stmt.ast.else_expr);
}

fn visitSwitch(self: *SemanticBuilder, _: NodeIndex, condition: NodeIndex, cases: []NodeIndex) !void {
    const ast = self.AST();

    try self.visitNode(condition);
    try self.enterScope(.{});
    defer self.exitScope();

    for (cases) |case_id| {
        const case = ast.fullSwitchCase(case_id) orelse unreachable;
        try self.enterNode(case_id);
        defer self.exitNode();
        try self.visitSwitchCase(case_id, case);
    }
}

fn visitSwitchCase(self: *SemanticBuilder, _: NodeIndex, case: full.SwitchCase) !void {
    for (case.ast.values) |value| {
        try self.visit(value);
    }
    try self.visit(case.ast.target_expr);
}

fn visitCatch(self: *SemanticBuilder, node_id: NodeIndex) !void {
    const ast = self.AST();
    const token_tags: []Token.Tag = ast.tokens.items(.tag);
    const data = self.getNodeData(node_id);

    const fallback_first = ast.firstToken(data.rhs);
    const main_token = ast.nodes.items(.main_token)[node_id];

    try self.enterScope(.{ .s_catch = true });
    defer self.exitScope();

    if (token_tags[fallback_first - 1] == .pipe) {
        const identifier = self.getIdentifier(main_token) orelse return SemanticError.MissingIdentifier;
        _ = try self.declareSymbol(.{
            .name = identifier,
            .visibility = .private,
            .flags = .{ .s_catch_param = true },
        });
    } else {
        assert(token_tags[fallback_first - 1] == .keyword_catch);
    }

    return self.visit(data.rhs);
}

inline fn visitFnProto(self: *SemanticBuilder, _: NodeIndex, fn_proto: full.FnProto) !void {
    try self.enterScope(.{});
    defer self.exitScope();
    for (fn_proto.ast.params) |param| {
        try self.visit(param);
    }
}

inline fn visitFnDecl(self: *SemanticBuilder, node_id: NodeIndex) !void {
    var buf: [1]u32 = undefined;
    const ast = self.AST();
    // lhs is prototype, rhs is body
    // const data: Node.Data = ast.nodes.items(.data)[node_id];
    const data = self.getNodeData(node_id);
    const proto = ast.fullFnProto(&buf, data.lhs) orelse unreachable;
    const visibility = if (proto.visib_token == null) Symbol.Visibility.private else Symbol.Visibility.public;
    // TODO: bound name vs escaped name
    const identifier: ?string = if (proto.name_token) |tok| self.getIdentifier(tok) else null;
    const debug_name: ?string = if (identifier == null) "<anonymous fn>" else null;
    // TODO: bind methods as members
    _ = try self.bindSymbol(.{
        .name = identifier,
        .debug_name = debug_name,
        .visibility = visibility,
        .flags = .{ .s_fn = true },
    });

    var fn_signature_implies_comptime = false;
    const tags: []Node.Tag = ast.nodes.items(.tag);
    for (proto.ast.params) |param_id| {
        if (tags[param_id] == .@"comptime") {
            fn_signature_implies_comptime = true;
            break;
        }
    }
    fn_signature_implies_comptime = fn_signature_implies_comptime or std.mem.eql(u8, ast.getNodeSource(proto.ast.return_type), "type");

    // parameters are in a new scope b/c other symbols in the same scope as
    // the declared fn cannot access them.
    const was_comptime = self.setScopeFlag("s_comptime", fn_signature_implies_comptime);
    defer self.restoreScopeFlag("s_comptime", was_comptime);
    try self.enterScope(.{});
    defer self.exitScope();
    for (proto.ast.params) |param| {
        try self.visit(param);
    }

    // Function body is also in a new scope. Declaring a symbol with the
    // same name as a parameter is an illegal shadow, not a redeclaration
    // error.
    try self.enterScope(.{ .s_function = true });
    defer self.exitScope();
    try self.visit(data.rhs);
}

/// Visit a function call. Does not visit calls to builtins
inline fn visitCall(self: *SemanticBuilder, _: NodeIndex, call: full.Call) !void {
    // TODO: record reference
    try self.visit(call.ast.fn_expr);
    for (call.ast.params) |arg| {
        try self.visit(arg);
    }
}
// =========================================================================
// ======================== SCOPE/SYMBOL MANAGEMENT ========================
// =========================================================================

fn enterRoot(self: *SemanticBuilder) !void {
    @setCold(true);

    // initialize root scope
    // NOTE: root scope is entered differently to avoid unnecessary null checks
    // when getting parent scopes. Parent is only ever null for the root scope.
    util.assert(self._scope_stack.items.len == 0, "enterRoot called with non-empty scope stack", .{});
    const root_scope_id = try self._semantic.scopes.addScope(self._gpa, null, .{ .s_top = true });
    util.assert(root_scope_id == Semantic.ROOT_SCOPE_ID, "Creating root scope returned id {d} which is not the expected root id ({d})", .{ root_scope_id, Semantic.ROOT_SCOPE_ID });

    // SemanticBuilder.init() allocates enough space for 8 scopes.
    self._scope_stack.appendAssumeCapacity(root_scope_id);

    // push root node onto the stack. It is never popped.
    // Similar to root scope, the root node is pushed differently than
    // other nodes because parent->child node linking is skipped.
    self._node_stack.appendAssumeCapacity(Semantic.ROOT_NODE_ID);

    // Create root symbol and push it onto the stack. It too is never popped.
    // TODO: distinguish between bound name and escaped name.
    const root_symbol_id = try self.declareSymbol(.{
        .debug_name = "@This()",
        .flags = .{ .s_const = true },
    });
    util.assert(root_symbol_id == 0, "Creating root symbol returned id {d} which is not the expected root id (0)", .{root_symbol_id});
    try self.enterContainerSymbol(root_symbol_id);
}

/// Panic if we're not currently within the root scope and node.
///
/// This function gets erased in ReleaseFast builds.
inline fn assertRoot(self: *const SemanticBuilder) void {
    self.assertCtx(self._scope_stack.items.len == 1, "assertRoot: scope stack is not at root", .{});
    self.assertCtx(self._scope_stack.items[0] == Semantic.ROOT_SCOPE_ID, "assertRoot: scope stack is not at root", .{});

    self.assertCtx(self._node_stack.items.len == 1, "assertRoot: node stack is not at root", .{});
    self.assertCtx(self._node_stack.items[0] == Semantic.ROOT_NODE_ID, "assertRoot: node stack is not at root", .{});

    self.assertCtx(self._symbol_stack.items.len == 1, "assertRoot: symbol stack is not at root", .{});
    self.assertCtx(self._symbol_stack.items[0] == 0, "assertRoot: symbol stack is not at root", .{}); // TODO: create root symbol id.
}

/// Update a single flag on the set of current scope flags, returning its
/// previous value.
///
/// ## Example
/// ```zig
/// fn visitSomeNode(self: *SemanticBuilder, node_id: NodeIndex) !void {
///    const children = self.getNodeData(node_id);
///
///    const was_comptime = self.setScopeFlag("s_comptime", true);
///    defer self.restoreScopeFlag("s_comptime", was_comptime);  // reset after we leave the new scope
///    try self.enterScope(.{ .s_block = true });
///    defer self.exitScope();
///
///    try self.visit(children.lhs);
/// }
/// ```
inline fn setScopeFlag(self: *SemanticBuilder, comptime flag_name: string, value: bool) bool {
    const old_flag: bool = @field(self._curr_scope_flags, flag_name);
    @field(self._curr_scope_flags, flag_name) = value;
    return old_flag;
}

/// Restore the builder's current scope flags to a checkpoint. Used in tandem
/// with `resetScopeFlags`.
inline fn restoreScopeFlag(self: *SemanticBuilder, comptime flag_name: string, prev_value: bool) void {
    @field(self._curr_scope_flags, flag_name) = prev_value;
}

/// Enter a new scope, pushing it onto the stack.
fn enterScope(self: *SemanticBuilder, flags: Scope.Flags) !void {
    const parent_id = self._scope_stack.getLastOrNull();
    const merged_flags = flags.merge(self._curr_scope_flags);
    const scope = try self._semantic.scopes.addScope(self._gpa, parent_id, merged_flags);
    try self._scope_stack.append(self._gpa, scope);
}

/// Exit the current scope. It is a bug to pop the root scope.
inline fn exitScope(self: *SemanticBuilder) void {
    self.assertCtx(self._scope_stack.items.len > 1, "Invariant violation: cannot pop the root scope", .{});
    _ = self._scope_stack.pop();
}

/// Get the current scope.
///
/// This should never panic because the root scope is never exited.
inline fn currentScope(self: *const SemanticBuilder) Scope.Id {
    assert(self._scope_stack.items.len != 0);
    return self._scope_stack.getLast();
}

inline fn currentNode(self: *const SemanticBuilder) NodeIndex {
    self.assertCtx(self._node_stack.items.len > 0, "Invariant violation: root node is missing from the node stack", .{});
    return self._node_stack.getLast();
}

inline fn enterNode(self: *SemanticBuilder, node_id: NodeIndex) !void {
    if (IS_DEBUG) {
        self._checkForNodeLoop(node_id);
    }
    const curr_node = self.currentNode();
    self._semantic.node_links.setParent(node_id, curr_node);
    self._semantic.node_links.setScope(node_id, self.currentScope());
    try self._node_stack.append(self._gpa, node_id);
}

inline fn exitNode(self: *SemanticBuilder) void {
    self.assertCtx(self._node_stack.items.len > 0, "Invariant violation: Cannot pop the root node", .{});
    _ = self._node_stack.pop();
}

/// Check for a visit loop when pushing `node_id` onto the node stack.
/// Panics if it finds one.
///
/// Should only be run in debug builds.
fn _checkForNodeLoop(self: *SemanticBuilder, node_id: NodeIndex) void {
    var is_loop = false;
    for (self._node_stack.items) |id| {
        if (node_id == id) {
            is_loop = true;
            break;
        }
    }
    self.assertCtx(!is_loop, "Invariant violation: Node {d} is already on the stack", .{node_id});
}

inline fn enterContainerSymbol(self: *SemanticBuilder, symbol_id: Symbol.Id) Allocator.Error!void {
    try self._symbol_stack.append(self._gpa, symbol_id);
}

/// Pop the most recent container symbol from the stack. Panics if the symbol stack is empty.
inline fn exitContainerSymbol(self: *SemanticBuilder) void {
    // NOTE: asserts stack is not empty
    _ = self._symbol_stack.pop();
}

/// Get the most recent container symbol, returning `null` if the stack is empty.
///
/// `null` returns happen, for example, in the root scope. or within root
/// functions.
inline fn currentContainerSymbol(self: *const SemanticBuilder) ?Symbol.Id {
    return self._symbol_stack.getLastOrNull();
}

/// Unconditionally get the most recent container symbol. Panics if no
/// symbol has been entered.
inline fn currentContainerSymbolUnwrap(self: *const SemanticBuilder) Symbol.Id {
    self.assertCtx(
        self._symbol_stack.items.len > 0,
        "Invariant violation: no container symbol on the stack. Root symbol should always be present.",
        .{},
    );
    return self._symbol_stack.getLast();
}

/// Data used to declare a new symbol
const DeclareSymbol = struct {
    /// AST Node declaring the symbol. Defaults to the current node.
    declaration_node: ?NodeIndex = null,
    /// Name of the identifier bound to this symbol. May be missing for
    /// anonymous symbols. In these cases, provide a `debug_name`.
    name: ?string = null,
    /// An optional debug name for anonymous symbols
    debug_name: ?string = null,
    /// Visibility to external code. Defaults to public.
    visibility: Symbol.Visibility = .public,
    flags: Symbol.Flags = .{},
    /// The scope where the symbol is declared. Defaults to the current scope.
    scope_id: ?Scope.Id = null,
};

/// Create and bind a symbol to the current scope and container (parent) symbol.
///
/// Panics if the parent is a member symbol.
fn bindSymbol(self: *SemanticBuilder, opts: DeclareSymbol) !Symbol.Id {
    const symbol_id = try self.declareSymbol(opts);
    if (self.currentContainerSymbol()) |container_id| {
        assert(!self._semantic.symbols.get(container_id).flags.s_member);
        try self._semantic.symbols.addMember(self._gpa, symbol_id, container_id);
    }

    return symbol_id;
}

/// Declare a new symbol in the current scope/AST node and record it as a member to
/// the most recent container symbol. Returns the new member symbol's ID.
fn declareMemberSymbol(
    self: *SemanticBuilder,
    opts: DeclareSymbol,
) !Symbol.Id {
    var options = opts;
    options.flags.s_member = true;
    const member_symbol_id = try self.declareSymbol(options);

    const container_symbol_id = self.currentContainerSymbolUnwrap();
    assert(!self._semantic.symbols.get(container_symbol_id).flags.s_member);
    try self._semantic.symbols.addMember(self._gpa, member_symbol_id, container_symbol_id);

    return member_symbol_id;
}

/// Declare a symbol in the current scope. Symbols created this way are not
/// associated with a container symbol's members or exports.
inline fn declareSymbol(
    self: *SemanticBuilder,
    opts: DeclareSymbol,
) !Symbol.Id {
    const scope = opts.scope_id orelse self.currentScope();
    const symbol_id = try self._semantic.symbols.addSymbol(
        self._gpa,
        opts.declaration_node orelse self.currentNode(),
        opts.name,
        opts.debug_name,
        scope,
        opts.visibility,
        opts.flags,
    );
    try self._semantic.scopes.addBinding(self._gpa, scope, symbol_id);
    return symbol_id;
}

// =========================================================================
// ============================ RANDOM GETTERS =============================
// =========================================================================

/// Shorthand for getting the AST. Must be caps to avoid shadowing local
/// `ast` declarations.
inline fn AST(self: *const SemanticBuilder) *const Ast {
    return &self._semantic.ast;
}

/// Shorthand for getting the symbol table.
inline fn symbolTable(self: *SemanticBuilder) *Semantic.SymbolTable {
    return &self._semantic.symbols;
}

/// Shorthand for getting the scope tree.
inline fn scopeTree(self: *SemanticBuilder) *Semantic.ScopeTree {
    return &self._semantic.scopes;
}

inline fn getNodeData(self: *const SemanticBuilder, node_id: NodeIndex) Node.Data {
    return self.AST().nodes.items(.data)[node_id];
}

/// Get a node by its ID.
///
/// ## Panics
/// - If attempting to access the root node (which acts as null).
/// - If `node_id` is out of bounds.
inline fn getNode(self: *const SemanticBuilder, node_id: NodeIndex) Node {
    // root node (whose id is 0) is used as null
    // NOTE: do not use assert here b/c that gets stripped in release
    // builds. We want more safety here.
    if (node_id == 0) @panic("attempted to access null node");
    assert(node_id < self.AST().nodes.len);

    return self.AST().nodes.get(node_id);
}

/// Get a node by its ID, returning `null` if its the root node (which acts as null).
///
/// ## Panics
/// - If `node_id` is out of bounds.
inline fn maybeGetNode(self: *const SemanticBuilder, node_id: NodeIndex) ?Node {
    {
        if (node_id == 0) return null;
        const len = self.AST().nodes.len;
        self.assertCtx(
            node_id < len,
            "Cannot get node: id {d} is out of bounds ({d})",
            .{ node_id, len },
        );
    }

    return self.AST().nodes.get(node_id);
}

inline fn getTokenTag(self: *const SemanticBuilder, token_id: TokenIndex) Token.Tag {
    return self._semantic.ast.tokens.items(.tag)[token_id];
}

inline fn getToken(self: *const SemanticBuilder, token_id: TokenIndex) RawToken {
    const len = self.AST().tokens.len;
    util.assert(
        token_id < len,
        "Cannot get token: id {d} is out of bounds ({d})",
        .{ token_id, len },
    );

    const t = self.AST().tokens.get(token_id);
    return .{
        .tag = t.tag,
        .start = t.start,
    };
}

/// Get an identifier name from an `.identifier` token.
fn getIdentifier(self: *SemanticBuilder, token_id: Ast.TokenIndex) ?string {
    const ast = self.AST();

    const tag = ast.tokens.items(.tag)[token_id];
    return if (tag == .identifier) ast.tokenSlice(token_id) else null;
}

// =========================================================================
// =========================== ERROR MANAGEMENT ============================
// =========================================================================

fn addAstError(self: *SemanticBuilder, ast: *const Ast, ast_err: Ast.Error) !void {
    var msg: std.ArrayListUnmanaged(u8) = .{};
    defer msg.deinit(self._gpa);
    try ast.renderError(ast_err, msg.writer(self._gpa));

    // TODO: render `ast_err.extra.expected_tag`
    const byte_offset: Ast.ByteOffset = ast.tokens.items(.start)[ast_err.token];
    const loc = ast.tokenLocation(byte_offset, ast_err.token);
    const labels = .{
        Span{ .start = @intCast(loc.line_start), .end = @intCast(loc.line_end) },
    };
    _ = labels;

    return self.addErrorOwnedMessage(try msg.toOwnedSlice(self._gpa), null);
}

/// Record an error encountered during parsing or analysis.
///
/// All parameters are borrowed. Errors own their data, so each parameter gets cloned onto the heap.
fn addError(self: *SemanticBuilder, message: string, labels: []Span, help: ?string) !void {
    const alloc = self._errors.allocator;
    const heap_message = try alloc.dupeZ(u8, message);
    const heap_labels = try alloc.dupe(Span, labels);
    const heap_help: ?string = if (help == null) null else try alloc.dupeZ(help.?);
    const err = try Error{
        .message = .{ .str = heap_message, .static = false },
        .labels = heap_labels,
        .help = heap_help,
    };
    try self._errors.append(err);
}

/// Create and record an error. `message` is an owned slice moved into the new Error.
// fn addErrorOwnedMessage(self: *SemanticBuilder, message: string, labels: []Span, help: ?string) !void {
fn addErrorOwnedMessage(self: *SemanticBuilder, message: string, help: ?string) !void {
    // const heap_labels = try alloc.dupe(labels);
    const heap_help: ?string = if (help == null) null else try self._gpa.dupeZ(u8, help.?);
    var err = Error.new(message);
    err.help = heap_help;
    try self._errors.append(self._gpa, err);
}

// =========================================================================
// ====================== PANICS AND DEBUGGING UTILS =======================
// =========================================================================

const print = std.debug.print;

/// Assert a condition, and print current stack debug info if it fails.
inline fn assertCtx(self: *const SemanticBuilder, condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (IS_DEBUG) {
        if (!condition) {
            print("Assertion failed: ", .{});
            print(fmt, args);
            print("\n================================================================================\n", .{});
            print("\nContext:\n\n", .{});
            self.debugNodeStack();
            print("\n", .{});
            self.printSymbolStack();
            print("\n", .{});
            self.printScopeStack();
            print("\n", .{});
            std.debug.assert(false);
        }
    } else {
        assert(condition);
    }
}

fn debugNodeStack(self: *const SemanticBuilder) void {
    @setCold(true);
    const ast = self.AST();

    print("Node stack:\n", .{});
    for (self._node_stack.items) |id| {
        const tag: Node.Tag = ast.nodes.items(.tag)[id];
        const main_token = ast.nodes.items(.main_token)[id];
        const token_offset = ast.tokens.get(main_token).start;

        const source = if (id == 0) "" else ast.getNodeSource(id);
        const loc = ast.tokenLocation(token_offset, main_token);
        const snippet =
            if (source.len > 48) std.mem.concat(
            self._gpa,
            u8,
            &[_]string{ source[0..32], " ... ", source[(source.len - 16)..source.len] },
        ) catch @panic("Out of memory") else source;
        print("  - [{d}, {d}:{d}] {any} - {s}\n", .{ id, loc.line, loc.column, tag, snippet });
        if (!std.mem.eql(u8, source, snippet)) {
            self._gpa.free(snippet);
        }
    }
}

fn printSymbolStack(self: *const SemanticBuilder) void {
    @setCold(true);
    const symbols = &self._semantic.symbols;
    const names: []string = symbols.symbols.items(.name);

    print("Symbol stack:\n", .{});
    for (self._symbol_stack.items) |id| {
        const name = names[id];
        print("  - {d}: {s}\n", .{ id, name });
    }
}

fn printScopeStack(self: *const SemanticBuilder) void {
    @setCold(true);
    const scopes = &self._semantic.scopes;

    print("Scope stack:\n", .{});
    const scope_flags = scopes.scopes.items(.flags);
    for (self._scope_stack.items) |id| {
        // const flags = scopes.scopes.items[id].flags;
        print("  - {d}: (flags: {any})\n", .{ id, scope_flags[id] });
    }
}

const SemanticBuilder = @This();

const Semantic = @import("./Semantic.zig");
const Scope = Semantic.Scope;
const Symbol = Semantic.Symbol;
const NodeLinks = Semantic.NodeLinks;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Type = std.builtin.Type;

const assert = std.debug.assert;

const Ast = std.zig.Ast;
const full = Ast.full;
const Token = std.zig.Token;
const Node = Ast.Node;
const NodeIndex = Ast.Node.Index;
/// The struct used in AST tokens SOA is not pub so we hack it in here.
const RawToken = struct {
    tag: std.zig.Token.Tag,
    start: u32,
};
const TokenIndex = Ast.TokenIndex;

const Error = @import("../Error.zig");
const Span = @import("../source.zig").Span;

const util = @import("util");
const IS_DEBUG = util.IS_DEBUG;
const string = util.string;
const stringSlice = util.stringSlice;

test "Struct/enum fields are bound bound to the struct/enums's member table" {
    const alloc = std.testing.allocator;
    const programs = [_][:0]const u8{
        "const Foo = struct { bar: u32 };",
        "const Foo = enum { bar };",
    };
    for (programs) |program| {
        var builder = SemanticBuilder.init(alloc);
        defer builder.deinit();
        var result = try builder.build(program);
        defer result.deinit();
        try std.testing.expect(!result.hasErrors());
        var semantic = result.value;

        // Find Foo and bar symbols
        var foo: ?*const Semantic.Symbol = null;
        var bar: ?*const Semantic.Symbol = null;
        {
            var iter = semantic.symbols.iter();
            const names = semantic.symbols.symbols.items(.name);
            while (iter.next()) |id| {
                const name = names[id];
                if (std.mem.eql(u8, name, "bar")) {
                    bar = semantic.symbols.get(id);
                } else if (std.mem.eql(u8, name, "Foo")) {
                    foo = semantic.symbols.get(id);
                }
            }
        }

        // they exist
        try std.testing.expect(bar != null);
        try std.testing.expect(foo != null);
        try std.testing.expect(bar.?.scope != Semantic.ROOT_SCOPE_ID);
        // Foo has exactly 1 member and it is bar
        const foo_members = semantic.symbols.getMembers(foo.?.id);
        try std.testing.expectEqual(1, foo_members.items.len);
        try std.testing.expectEqual(bar.?.id, foo_members.items[0]);
    }
}

test "comptime blocks" {
    const alloc = std.testing.allocator;
    const src =
        \\const x = blk: {
        \\  const y = 1;
        \\  break :blk y + 1;
        \\};
    ;
    var builder = SemanticBuilder.init(alloc);
    defer builder.deinit();
    var result = try builder.build(src);
    defer result.deinit();
    try std.testing.expect(!result.hasErrors());
    var semantic = result.value;

    const scopes = &semantic.scopes.scopes;
    try std.testing.expectEqual(2, scopes.len);

    const block_scope = scopes.get(1);
    try std.testing.expect(block_scope.flags.s_block);
    try std.testing.expect(block_scope.flags.s_comptime);
}
