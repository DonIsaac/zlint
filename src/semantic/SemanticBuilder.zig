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

_source_code: ?_source.ArcStr = null,
_source_path: ?string = null,

// states
_curr_scope_flags: Scope.Flags = .{},
_curr_symbol_flags: Symbol.Flags = .{},
_curr_reference_flags: Reference.Flags = .{ .read = true },
/// Flags added to the next block-created scope. Reset immediately after use.
///
/// Nodes whose children may or may not be a block scope must be careful to
/// reset this themselves. Although `visitBlock` will reset these flags, if a
/// non-block node is encountered, it will not be reset.
_next_block_scope_flags: Scope.Flags = .{},

// stacks
_scope_stack: std.ArrayListUnmanaged(Semantic.Scope.Id) = .{},
/// When entering an initialization container for a symbol, that symbol's ID
/// is pushed here. This lets us record members and exports.
_symbol_stack: std.ArrayListUnmanaged(Semantic.Symbol.Id) = .{},
_node_stack: std.ArrayListUnmanaged(NodeIndex) = .{},
/// References encountered but that could not be resolved. Includes references
/// that occur before symbol declaration, and we haven't seen the declaration yet.
/// After analysis, references in this list are to symbols not declared anywhere
/// in the source.
///
/// We try to resolve these each time a scope is exited.
_unresolved_references: ReferenceStack = .{},

/// SAFETY: initialized after parsing.
_semantic: Semantic = undefined,
/// Errors encountered during parsing and analysis.
///
/// Errors in this list are allocated using this list's allocator.
_errors: std.ArrayListUnmanaged(Error) = .{},

/// The root node always has an index of 0. Since it is never referenced by other nodes,
/// the Zig team uses it to represent `null` without wasting extra memory.
const NULL_NODE: NodeIndex = Semantic.NULL_NODE;
const ROOT_SCOPE: Semantic.Scope.Id = Semantic.ROOT_SCOPE_ID;
const BUILTIN_SCOPE: Semantic.Scope.Id = Semantic.BUILTIN_SCOPE_ID;

pub const Result = Error.Result(Semantic);
pub const SemanticError = error{
    ParseFailed,
    /// Expected `ast.fullFoo` to return `Some(foo)` but it returned `None`,
    FullMismatch,
    /// Expected an identifier name, but none was found.
    MissingIdentifier,
    UnexpectedToken,
} || Allocator.Error;

pub fn init(gpa: Allocator) SemanticBuilder {
    return .{
        ._gpa = gpa,
        ._arena = ArenaAllocator.init(gpa),
    };
}

pub fn withSource(self: *SemanticBuilder, source: *const _source.Source) void {
    self._source_code = source.contents.clone();
    self._source_path = source.pathname;
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

    // resolve references to symbols declared in root
    try builder.resolveReferencesInCurrentScope();
    // Take whatever references still haven't been resolved and move them to
    // Semantic.
    const unresolved_frame_count = builder._unresolved_references.len();
    switch (unresolved_frame_count) {
        0 => builder._semantic.symbols.unresolved_references = .{},
        1 => {
            const unresolved = try builder._unresolved_references.curr().toOwnedSlice(builder._gpa);
            builder._semantic.symbols.unresolved_references = .{
                .items = unresolved,
                .capacity = unresolved.len,
            };
        },
        else => std.debug.panic("Expected 0 or 1 frame, got {d}", .{unresolved_frame_count}),
    }

    return Result.new(builder._gpa, builder._semantic, builder._errors);
}

/// Deinitialize build-specific resources. Errors and the constructed
/// `Semantic` instance are left untouched.
pub fn deinit(self: *SemanticBuilder) void {
    self._scope_stack.deinit(self._gpa);
    self._symbol_stack.deinit(self._gpa);
    self._node_stack.deinit(self._gpa);
    self._unresolved_references.deinit(self._gpa);
    if (self._source_code) |*src| src.deinit();
}

fn parse(self: *SemanticBuilder, source: stringSlice) Allocator.Error!Ast {
    const alloc = self._arena.allocator();
    var ast = try Ast.parse(self._arena.allocator(), source, .zig);
    errdefer ast.deinit(alloc);

    // Record parse errors
    if (ast.errors.len > 0) {
        try self._errors.ensureUnusedCapacity(self._gpa, ast.errors.len);
        for (ast.errors) |ast_err| {
            // Not an error. TODO: verify this assumption
            if (ast_err.is_note) continue;
            try self.addAstError(&ast, ast_err);
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
fn visit(self: *SemanticBuilder, node_id: NodeIndex) SemanticError!void {
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

        // variable/field declarations
        .container_field, .container_field_align, .container_field_init => {
            const field = ast.fullContainerField(node_id) orelse unreachable;
            return self.visitContainerField(node_id, field);
        },
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            const decl = self.AST().fullVarDecl(node_id) orelse unreachable;
            return self.visitVarDecl(node_id, decl);
        },
        .assign_destructure => {
            const destructure = ast.assignDestructure(node_id);
            return self.visitAssignDestructure(node_id, destructure);
        },

        // variable/field references
        .identifier => return self.visitIdentifier(node_id),
        .field_access => return self.visitFieldAccess(node_id),

        // initializations
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
        // assignment
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        .assign,
        => return self.visitAssignment(node_id, tag),
        // function-related nodes

        // function declarations
        .fn_decl,
        => return self.visitFnDecl(node_id),
        .fn_proto, .fn_proto_one, .fn_proto_simple, .fn_proto_multi => {
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

        .test_decl => {
            const prev = self.setScopeFlag(.s_comptime, false);
            defer self.restoreScopeFlag(.s_comptime, prev);
            self._next_block_scope_flags = .{ .s_test = true, .s_block = true };
            return self.visit(data[node_id].rhs);
        },

        // pointers

        // lhs is a token, rhs is a node
        .anyframe_type => return self.visit(data[node_id].rhs),
        // lhs is a node, rhs is an index into Slice
        .slice,
        .slice_sentinel,
        .slice_open,
        => return self.visitSlice(node_id),
        .ptr_type,
        .ptr_type_sentinel,
        .ptr_type_aligned,
        .ptr_type_bit_range,
        => {
            const ptr = self.AST().fullPtrType(node_id) orelse @panic("expected node to be a ptr type");
            return self.visitPtrType(ptr);
        },

        // lhs/rhs for these nodes are always undefined
        .char_literal,
        .number_literal,
        .unreachable_literal,
        .string_literal,
        .anyframe_literal,
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
            const prev_comptime = self.setScopeFlag(.s_comptime, true);
            defer self.restoreScopeFlag(.s_comptime, prev_comptime);

            return self.visit(data[node_id].lhs);
        },

        // lhs is undefined, rhs is a token index
        // see: Parse.zig, line 2934
        // TODO: visit block
        .error_set_decl => return self.visitErrorSetDecl(node_id),

        // lhs is a node, rhs is a token
        .grouped_expression,
        .unwrap_optional,
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

/// Like `visit`, but turns off `read`/`write` reference flags and turns on `type`.
inline fn visitType(self: *SemanticBuilder, node_id: NodeIndex) !void {
    const prev = self.takeReferenceFlags();
    defer self._curr_reference_flags = prev;
    self._curr_reference_flags.type = true;
    try self.visit(node_id);
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
    const NON_COMPTIME_BLOCKS: Scope.Flags = .{ .s_test = true, .s_block = true, .s_function = true };
    const is_root = self.currentScope() == ROOT_SCOPE;
    const is_comptime = is_root and !self._curr_scope_flags.intersects(NON_COMPTIME_BLOCKS);
    const was_comptime = self._curr_scope_flags.s_comptime;

    self._curr_scope_flags.s_comptime = is_comptime;
    defer self._curr_scope_flags.s_comptime = was_comptime;

    const flags = self._next_block_scope_flags.merge(.{ .s_block = true });
    self._next_block_scope_flags = .{};

    try self.enterScope(.{ .flags = flags });
    defer self.exitScope();

    for (statements) |stmt| {
        try self.visit(stmt);
    }
}

fn visitContainer(self: *SemanticBuilder, node: NodeIndex, container: full.ContainerDecl) !void {
    const main_tokens: []const TokenIndex = self.AST().nodes.items(.main_token);
    const tags: []const Token.Tag = self.AST().tokens.items(.tag);

    const scope_flags: Scope.Flags, const symbol_flags: Symbol.Flags = switch (tags[main_tokens[node]]) {
        .keyword_enum => .{ .{ .s_enum = true }, .{ .s_enum = true } },
        .keyword_struct => .{ .{ .s_struct = true }, .{ .s_struct = true } },
        .keyword_union => .{ .{ .s_union = true }, .{ .s_union = true } },
        // e.g. opaque
        else => .{ .{}, .{} },
    };

    self.currentContainerSymbolFlags().set(symbol_flags, true);
    self._curr_symbol_flags.set(symbol_flags, true);
    defer self._curr_symbol_flags.set(symbol_flags, true);

    try self.enterScope(.{
        .flags = scope_flags.merge(.{ .s_block = true }),
    });
    defer self.exitScope();
    for (container.ast.members) |member| {
        try self.visit(member);
    }
}

fn visitErrorSetDecl(self: *SemanticBuilder, node_id: NodeIndex) !void {
    // util.assertUnsafe(self.AST().nodes.items(.tag)[node_id] == Node.Tag.error_set_decl);
    const tags: []const Token.Tag = self.AST().tokens.items(.tag);

    var curr_tok = self.getNodeData(node_id).rhs;
    util.debugAssert(tags[curr_tok] == Token.Tag.r_brace, "error_set_decl rhs should be an rbrace token.", .{});
    curr_tok -= 1;

    try self.enterScope(.{ .flags = .{ .s_error = true } });
    defer self.exitScope();
    self.currentContainerSymbolFlags().s_error = true;

    while (true) : (curr_tok -= 1) {
        // NOTE: causes an out-of-bounds access in release builds, but the
        // assertion never fails in debug builds. TODO: investigate and report
        // to Zig team.
        // util.assertUnsafe(curr_tok > 0);
        util.assert(
            curr_tok > 0,
            "an brace should always be encountered when walking an error declaration's members in a syntactically-valid program.",
            .{},
        );
        switch (tags[curr_tok]) {
            .identifier => {
                _ = try self.declareMemberSymbol(.{
                    .declaration_node = node_id,
                    .identifier = curr_tok,
                    .visibility = Symbol.Visibility.public,
                    .flags = .{ .s_error = true },
                });
            },
            .comma, .doc_comment => {},
            .l_brace => break,
            else => {
                // in debug builds we want to know if we're missing something or
                // handling errors incorrectly. in release mode we can safely
                // ignore it.
                util.debugAssert(false, "unexpected token in error container: {any}", .{tags[curr_tok]});
                break;
            },
        }
    }
}

/// ======================= VARIABLE/FIELD DECLARATIONS ========================
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
    const identifier = self.expectToken(main_token, .identifier);
    _ = try self.declareMemberSymbol(.{
        .identifier = identifier,
        .flags = .{
            .s_comptime = field.comptime_token != null,
        },
    });
    const parent = self.currentContainerSymbolUnwrap().into(usize);

    try self.visit(field.ast.align_expr);
    // NOTE: do not move this to the top of the function b/c for some reason it
    // causes a segfault in release builds
    const flags: []const Symbol.Flags = self.symbolTable().symbols.items(.flags);
    if (!flags[parent].s_enum) {
        try self.visitType(field.ast.type_expr);
    }
    try self.visit(field.ast.value_expr);
}

/// Visit a variable declaration. Global declarations are visited
/// separately, because their lhs/rhs nodes and main token mean different
/// things.
fn visitVarDecl(self: *SemanticBuilder, node_id: NodeIndex, var_decl: full.VarDecl) !void {
    // main_token points to `var`, `const` keyword. `.identifier` comes immediately afterwards
    const ast = self.AST();
    const main_token: TokenIndex = ast.nodes.items(.main_token)[node_id];

    const identifier = self.expectToken(main_token + 1, .identifier);
    // TODO: find out if this could legally be another kind of token
    // if (tags[identifier] != .identifier) return error.MissingIdentifier;
    // const debug_name: ?string = if (identifier == null) "<anonymous var decl>" else null;
    const debug_name = null;
    const visibility = if (var_decl.visib_token == null) Symbol.Visibility.private else Symbol.Visibility.public;
    const is_const: bool = blk: {
        const token_tags = ast.tokens.items(.tag);
        const main_tag = token_tags[main_token];
        if (util.IS_DEBUG) assert(main_tag == .keyword_var or main_tag == .keyword_const);
        break :blk main_tag == .keyword_const;
    };

    const prev_symbol_flags = self._curr_symbol_flags;
    self._curr_symbol_flags.set(Symbol.Flags.s_container, false);
    defer self._curr_symbol_flags = prev_symbol_flags;

    var flags: Symbol.Flags = .{
        .s_variable = true,
        .s_comptime = var_decl.comptime_token != null,
        .s_const = is_const,
    };

    if (var_decl.extern_export_token) |extern_export_token| {
        const offset = self.AST().tokens.items(.start)[extern_export_token];
        const source = self.AST().source;
        assert(source[offset] == 'e');
        assert(source[offset + 1] == 'x');
        if (source[offset + 2] == 't') {
            flags.s_extern = true;
        } else {
            assert(source[offset + 2] == 'p');
            flags.s_export = true;
        }
    }

    const symbol_id = try self.bindSymbol(.{
        .identifier = identifier,
        .debug_name = debug_name,
        .visibility = visibility,
        .flags = flags,
    });
    try self.enterContainerSymbol(symbol_id);
    defer self.exitContainerSymbol();
    try self.visitType(var_decl.ast.type_node);

    try self.visit(var_decl.ast.init_node);
}

// ================================ ASSIGNMENT =================================

fn visitAssignment(self: *SemanticBuilder, node_id: NodeIndex, tag: Node.Tag) SemanticError!void {
    const does_read_lhs = tag != .assign;
    const children = self.getNodeData(node_id);
    const flags = self._curr_reference_flags;
    defer self._curr_reference_flags = flags;

    {
        self._curr_reference_flags.write = true;
        self._curr_reference_flags.read = does_read_lhs;
        try self.visit(children.lhs);
    }
    {
        self._curr_reference_flags.read = true;
        self._curr_reference_flags.write = false;
        self._curr_reference_flags.call = false;
        try self.visit(children.rhs);
    }
}

fn visitAssignDestructure(
    self: *SemanticBuilder,
    _: NodeIndex,
    destructure: full.AssignDestructure,
) SemanticError!void {
    self.assertCtx(
        destructure.ast.variables.len > 0,
        "Invalid destructuring assignment: no variables are being declared.",
        .{},
    );
    const ast = self.AST();
    const main_tokens: []TokenIndex = ast.nodes.items(.main_token);
    const token_tags: []Token.Tag = ast.tokens.items(.tag);
    const is_comptime = destructure.comptime_token != null;

    for (destructure.ast.variables) |var_id| {
        const main_token: TokenIndex = main_tokens[var_id];
        const decl: full.VarDecl = ast.fullVarDecl(var_id) orelse {
            return SemanticError.FullMismatch;
        };
        // const identifier: ?string = self.getIdentifier(main_token + 1);
        const identifier = main_token + 1;
        if (token_tags[identifier] != .identifier) return error.MissingIdentifier;

        // note: intentionally not using bindSymbol (for now, at least)
        _ = try self.declareSymbol(.{
            .declaration_node = var_id,
            .identifier = identifier,
            .visibility = if (decl.visib_token != null) .public else .private,
            .flags = .{
                .s_variable = true,
                .s_comptime = is_comptime,
                .s_const = token_tags[main_token] == .keyword_const,
            },
        });
    }
    try self.visit(destructure.ast.value_expr);
}

// ========================= VARIABLE/FIELD REFERENCES  ========================

fn visitIdentifier(self: *SemanticBuilder, node_id: NodeIndex) !void {
    const ast = self.AST();
    const main_tokens = self.AST().nodes.items(.main_token);
    const identifier = try self.assertToken(main_tokens[node_id], .identifier);
    const symbol = self._semantic.resolveBinding(self.currentScope(), ast.tokenSlice(identifier));

    _ = try self.recordReference(.{
        .node = node_id,
        .symbol = symbol,
        .token = identifier,
    });
}

fn visitFieldAccess(self: *SemanticBuilder, node_id: NodeIndex) !void {
    // TODO: record references
    return self.visit(self.getNodeData(node_id).lhs);
}

fn visitSlice(self: *SemanticBuilder, node_id: NodeIndex) !void {
    const prev = self.takeReferenceFlags();
    defer self._curr_reference_flags = prev;
    self._curr_reference_flags.read = true;
    self._curr_reference_flags.write = false;
    self._curr_reference_flags.call = false;

    const slice: full.Slice = self.AST().fullSlice(node_id) orelse {
        const tags = self.AST().nodes.items(.tag);
        std.debug.panic("visitSlice called on non-slice: {}", .{tags[node_id]});
    };

    // sliced[start..end, :sentinel]
    // like field accesses, nodes are visit RTL
    try self.visit(slice.ast.start);
    try self.visit(slice.ast.end);
    try self.visit(slice.ast.sentinel);
    try self.visit(slice.ast.sliced);
}

fn visitPtrType(self: *SemanticBuilder, ptr: full.PtrType) !void {
    // TODO: add .type to reference flags?
    try self.visit(ptr.ast.align_node);
    try self.visit(ptr.ast.addrspace_node);
    try self.visit(ptr.ast.sentinel);
    try self.visit(ptr.ast.bit_range_start);
    try self.visit(ptr.ast.bit_range_end);
    try self.visit(ptr.ast.child_type);
}

// =============================================================================

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

inline fn visitFor(self: *SemanticBuilder, node: NodeIndex, for_stmt: full.For) !void {
    for (for_stmt.ast.inputs) |input| {
        try self.visit(input);
    }

    {
        const tags = self.AST().tokens.items(.tag);
        try self.enterScope(.{});
        defer self.exitScope();

        var curr = for_stmt.payload_token;
        while (true) {
            switch (tags[curr]) {
                .pipe => break,
                .asterisk, .comma => curr += 1,
                .identifier => {
                    _ = try self.declareSymbol(.{
                        .declaration_node = node,
                        .identifier = curr,
                        .flags = .{
                            .s_payload = true,
                            .s_const = true,
                        },
                    });
                    curr += 1;
                },
                else => return error.MissingIdentifier,
            }
        }
        try self.visit(for_stmt.ast.then_expr);
    }
    try self.visit(for_stmt.ast.else_expr);
}

inline fn visitIf(self: *SemanticBuilder, _: NodeIndex, if_stmt: full.If) !void {
    const ast = self.AST();
    const tags = ast.tokens.items(.tag);

    try self.visit(if_stmt.ast.cond_expr);

    // TODO: should payloads be in a separate scope as the block or naw?
    {
        // if (cond) |payload| then
        // payload is only available in `then`, not `else`
        try self.enterScope(.{});
        defer self.exitScope();
        defer self._next_block_scope_flags = .{};
        if (if_stmt.payload_token) |payload| {
            const identifier = if (tags[payload] == .identifier) payload else payload + 1;
            if (tags[identifier] != .identifier) return error.MissingIdentifier;
            _ = try self.declareSymbol(.{
                .declaration_node = if_stmt.ast.then_expr,
                .identifier = identifier,
                .flags = .{
                    .s_payload = true,
                    .s_const = true,
                },
            });
        }

        try self.visit(if_stmt.ast.then_expr);
    }
    {
        // same thing, but for else block
        try self.enterScope(.{});
        defer self.exitScope();
        defer self._next_block_scope_flags = .{};

        if (if_stmt.error_token) |payload| {
            const identifier = if (tags[payload] == .identifier) payload else payload + 1;
            if (tags[identifier] != .identifier) return error.MissingIdentifier;
            _ = try self.declareSymbol(.{
                .declaration_node = if_stmt.ast.else_expr,
                .identifier = identifier,
                .flags = .{
                    .s_payload = true,
                    .s_const = true,
                },
            });
        }

        try self.visit(if_stmt.ast.else_expr);
    }
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
        defer self._next_block_scope_flags = .{};
        try self.visitSwitchCase(case_id, case);
    }
}

fn visitSwitchCase(self: *SemanticBuilder, node: NodeIndex, case: full.SwitchCase) !void {
    for (case.ast.values) |value| try self.visit(value);

    if (case.payload_token) |payload_token| {
        const tags = self.AST().tokens.items(.tag);
        try self.enterScope(.{});
        var ident = payload_token;
        if (tags[ident] == .asterisk) ident += 1;
        if (tags[ident] != .identifier) return SemanticError.MissingIdentifier;
        _ = try self.bindSymbol(.{
            .declaration_node = node,
            .identifier = ident,
            .flags = .{ .s_payload = true, .s_const = true },
        });
    }
    defer if (case.payload_token != null) self.exitScope();

    try self.visit(case.ast.target_expr);
}

fn visitCatch(self: *SemanticBuilder, node_id: NodeIndex) !void {
    const ast = self.AST();
    const token_tags: []Token.Tag = ast.tokens.items(.tag);
    const data = self.getNodeData(node_id);

    try self.visit(data.lhs);

    const fallback_first = ast.firstToken(data.rhs);
    const main_token = ast.nodes.items(.main_token)[node_id];

    try self.enterScope(.{ .flags = .{ .s_catch = true } });
    defer self.exitScope();

    if (token_tags[fallback_first - 1] == .pipe) {
        const identifier: TokenIndex = try self.assertToken(main_token + 2, .identifier);
        _ = try self.declareSymbol(.{
            .identifier = identifier,
            .visibility = .private,
            .flags = .{
                .s_payload = true,
                .s_const = true,
                .s_catch_param = true,
            },
        });
    } else {
        assert(token_tags[fallback_first - 1] == .keyword_catch);
    }
    self._next_block_scope_flags.s_catch = true;
    defer self._next_block_scope_flags = .{};
    return self.visit(data.rhs);
}

inline fn visitFnProto(self: *SemanticBuilder, _: NodeIndex, fn_proto: full.FnProto) !void {
    try self.enterScope(.{ .flags = .{ .s_function = true } });
    defer self.exitScope();

    if (fn_proto.name_token) |name_token| {
        // const prev = self._curr_symbol_flags;
        // defer self._curr_symbol_flags = prev;
        var flags: Symbol.Flags = .{ .s_fn = true };
        if (fn_proto.extern_export_inline_token) |tok| {
            const ast = self.AST();
            const start = ast.tokens.items(.start)[tok];

            if (ast.source[start] == 'e') {
                if (ast.source[start + 2] == 't') {
                    // extern
                    flags.s_extern = true;
                } else {
                    // export
                    assert(ast.source[start + 2] == 'p');
                    flags.s_export = true;
                }
            }
        }
        _ = try self.bindSymbol(.{
            .identifier = name_token,
            .flags = flags,
            .visibility = if (fn_proto.visib_token) |_| .public else .private,
        });
    }

    try self.visitFnProtoParams(fn_proto);
    {
        const flags = self.takeReferenceFlags();
        defer self._curr_reference_flags = flags;
        self._curr_reference_flags.type = true;
        try self.visit(fn_proto.ast.return_type);
    }
}

fn visitFnProtoParams(self: *SemanticBuilder, fn_proto: full.FnProto) !void {
    const ast = self.AST();
    var it = fn_proto.iterate(ast);
    const tags = ast.tokens.items(.tag);

    while (it.next()) |param| {
        // NOTE: I don't think Zig creates identifier nodes for function
        // parameters. Checking out the nodes in fn_proto.ast.params, they are
        // the same as FnProto.Iterator uses for .type_expr.
        const node_id = param.type_expr;

        // bind parameter symbol
        if (param.name_token) |name_token| {
            // const identifier = ast.tokenSlice(name_token);
            const prev_tag: Token.Tag = tags[name_token - 1];
            _ = try self.declareSymbol(.{
                .declaration_node = node_id,
                // .name = identifier,
                .identifier = name_token,
                .flags = .{
                    .s_comptime = prev_tag == .keyword_comptime,
                    .s_fn_param = true,
                    .s_const = true, // function parameters are always implicitly const
                },
            });
        }

        try self.visit(param.type_expr);
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
    const debug_name: ?string = if (proto.name_token == null) "<anonymous fn>" else null;

    const prev_symbol_flags = self._curr_reference_flags;
    self._curr_symbol_flags.set(Symbol.Flags.s_container, false);
    defer self._curr_reference_flags = prev_symbol_flags;

    var flags: Symbol.Flags = .{ .s_fn = true };
    if (proto.extern_export_inline_token) |tok| {
        const start = ast.tokens.items(.start)[tok];
        if (ast.source[start] == 'e') {
            if (ast.source[start + 2] == 't') {
                // extern
                flags.s_extern = true;
            } else {
                // export
                assert(ast.source[start + 2] == 'p');
                flags.s_export = true;
            }
        }
    }
    // TODO: bind methods as members
    _ = try self.bindSymbol(.{
        .identifier = proto.name_token,
        .debug_name = debug_name,
        .visibility = visibility,
        .flags = flags,
    });

    var fn_signature_implies_comptime = false;
    const tags: []Node.Tag = ast.nodes.items(.tag);
    for (proto.ast.params) |param_id| {
        if (tags[param_id] == .@"comptime") {
            fn_signature_implies_comptime = true;
            break;
        }
    }
    fn_signature_implies_comptime = fn_signature_implies_comptime or mem.eql(u8, ast.getNodeSource(proto.ast.return_type), "type");

    // parameters are in a new scope b/c other symbols in the same scope as
    // the declared fn cannot access them.
    const was_comptime = self.setScopeFlag(.s_comptime, fn_signature_implies_comptime);
    defer self.restoreScopeFlag(.s_comptime, was_comptime);

    // note: intentionally not calling visitFnProto b/c we don't want the scope
    // created for params to exit until _after_ we visit the function body.
    try self.enterScope(.{
        .flags = .{ .s_function = true },
    });
    defer self.exitScope();
    try self.visitFnProtoParams(proto);
    {
        const ref_flags = self.takeReferenceFlags();
        defer self._curr_reference_flags = ref_flags;
        self._curr_reference_flags.type = true;
        try self.visit(proto.ast.return_type);
    }
    // TODO: visit return type. Note that return type is within param scope
    // (e.g. `fn foo(T: type) T`)

    // Function body is also in a new scope. Declaring a symbol with the
    // same name as a parameter is an illegal shadow, not a redeclaration
    // error.
    self._next_block_scope_flags.s_function = true;
    // try self.enterScope(.{
    //     .node = data.rhs,
    //     .flags = .{ .s_function = true },
    // });
    // defer self.exitScope();
    try self.visit(data.rhs);
    util.assert(
        self._next_block_scope_flags.eq(.{}),
        "Function body scope flags were not reset. This means the body was not a block node.",
        .{},
    );
}

/// Visit a function call. Does not visit calls to builtins
inline fn visitCall(self: *SemanticBuilder, _: NodeIndex, call: full.Call) !void {
    // TODO: record reference
    const prev = self._curr_reference_flags;
    // visit callee
    {
        self._curr_reference_flags.read = false;
        self._curr_reference_flags.write = false;
        self._curr_reference_flags.call = true;
        defer self._curr_reference_flags = prev;

        try self.visit(call.ast.fn_expr);
    }
    // visit each param
    {
        self._curr_reference_flags.read = true;
        self._curr_reference_flags.call = false;
        defer self._curr_reference_flags = prev;
        for (call.ast.params) |arg| {
            try self.visit(arg);
        }
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
    const root_scope_id = try self._semantic.scopes.addScope(
        self._gpa,
        null,
        Semantic.ROOT_NODE_ID,
        .{ .s_top = true },
    );
    util.assert(root_scope_id == Semantic.ROOT_SCOPE_ID, "Creating root scope returned id {d} which is not the expected root id ({d})", .{ root_scope_id, Semantic.ROOT_SCOPE_ID });

    // SemanticBuilder.init() allocates enough space for 8 scopes.
    self._scope_stack.appendAssumeCapacity(root_scope_id);
    try self._unresolved_references.enter(self._gpa);

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
    util.assert(root_symbol_id.int() == 0, "Creating root symbol returned id {d} which is not the expected root id (0)", .{root_symbol_id});
    try self.enterContainerSymbol(root_symbol_id);
}

/// Panic if we're not currently within the root scope and node.
///
/// This function gets erased in ReleaseFast builds.
inline fn assertRoot(self: *const SemanticBuilder) void {
    if (!util.IS_DEBUG) return // don't run assertions in any kind of release build

    self.assertCtx(self._scope_stack.items.len == 1, "assertRoot: scope stack is not at root", .{});
    self.assertCtx(self._scope_stack.items[0] == Semantic.ROOT_SCOPE_ID, "assertRoot: scope stack is not at root", .{});

    self.assertCtx(self._node_stack.items.len == 1, "assertRoot: node stack is not at root", .{});
    self.assertCtx(self._node_stack.items[0] == Semantic.ROOT_NODE_ID, "assertRoot: node stack is not at root", .{});

    self.assertCtx(self._symbol_stack.items.len == 1, "assertRoot: symbol stack is not at root", .{});
    self.assertCtx(self._symbol_stack.items[0].int() == 0, "assertRoot: symbol stack is not at root", .{}); // TODO: create root symbol id.
}

/// Update a single flag on the set of current scope flags, returning its
/// previous value. Use `restoreScopeFlag` afterwards to reset it to the
/// original value.
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
inline fn setScopeFlag(self: *SemanticBuilder, comptime flag: Scope.Flags.Flag, value: bool) bool {
    const flag_name = @tagName(flag);
    const old_flag: bool = @field(self._curr_scope_flags, flag_name);
    @field(self._curr_scope_flags, flag_name) = value;
    return old_flag;
}

/// Restore the builder's current scope flags to a checkpoint. Used in tandem
/// with `resetScopeFlags`.
inline fn restoreScopeFlag(self: *SemanticBuilder, comptime flag: Scope.Flags.Flag, prev_value: bool) void {
    const flag_name = @tagName(flag);
    @field(self._curr_scope_flags, flag_name) = prev_value;
}

const CreateScope = struct {
    flags: Scope.Flags = .{},
    node: ?NodeIndex = null,
};

/// Enter a new scope, pushing it onto the stack.
fn enterScope(self: *SemanticBuilder, opts: CreateScope) !void {
    const parent_id = self._scope_stack.getLastOrNull();
    const merged_flags = opts.flags.merge(self._curr_scope_flags);
    const node = opts.node orelse self.currentNode();

    const scope = try self._semantic.scopes.addScope(
        self._gpa,
        parent_id,
        node,
        merged_flags,
    );

    try self._scope_stack.append(self._gpa, scope);
    try self._unresolved_references.enter(self._gpa);
}

/// Exit the current scope. It is a bug to pop the root scope.
inline fn exitScope(self: *SemanticBuilder) void {
    self.assertCtx(self._scope_stack.items.len > 1, "Invariant violation: cannot pop the root scope", .{});
    self.resolveReferencesInCurrentScope() catch @panic("OOM");
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

fn enterNode(self: *SemanticBuilder, node_id: NodeIndex) !void {
    if (IS_DEBUG) self._checkForNodeLoop(node_id);
    const curr_node = self.currentNode();
    const curr_scope = self.currentScope();
    self._semantic.node_links.setParent(node_id, curr_node);
    self._semantic.node_links.setScope(node_id, curr_scope);
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

inline fn currentContainerSymbolFlags(self: *SemanticBuilder) *Symbol.Flags {
    return &self._semantic.symbols.symbols.items(.flags)[self.currentContainerSymbolUnwrap().int()];
}

/// Data used to declare a new symbol
const DeclareSymbol = struct {
    /// AST Node declaring the symbol. Defaults to the current node.
    declaration_node: ?NodeIndex = null,
    /// Name of the identifier bound to this symbol. May be missing for
    /// anonymous symbols. In these cases, provide a `debug_name`.
    identifier: ?TokenIndex = null,
    // name: ?string = null,
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
    const name = if (opts.identifier) |ident| self._semantic.ast.tokenSlice(ident) else null;
    const symbol_id = try self._semantic.symbols.addSymbol(
        self._gpa,
        opts.declaration_node orelse self.currentNode(),
        name,
        opts.debug_name,
        opts.identifier,
        scope,
        opts.visibility,
        opts.flags.merge(self._curr_symbol_flags),
    );
    try self._semantic.scopes.addBinding(self._gpa, scope, symbol_id);
    return symbol_id;
}

// =========================== Subsection: References ==========================

inline fn takeReferenceFlags(self: *SemanticBuilder) Reference.Flags {
    const flags = self._curr_reference_flags;
    self._curr_reference_flags = .{};
    return flags;
}

const CreateReference = struct {
    node: ?NodeIndex = null,
    token: ?TokenIndex = null,
    scope: ?Scope.Id = null,
    symbol: ?Symbol.Id = null,
    flags: Reference.Flags = .{},
};

fn recordReference(self: *SemanticBuilder, opts: CreateReference) SemanticError!Reference.Id {
    const ast = self.AST();
    const node = opts.node orelse self.currentNode();
    const scope = opts.scope orelse self.currentScope();
    const flags = opts.flags.merge(self._curr_reference_flags);
    const identifier_token: TokenIndex = opts.token orelse brk: {
        const mains: []const TokenIndex = ast.nodes.items(.main_token);
        // const token_tags = ast.tokens.items(.tag);
        const main_token: TokenIndex = mains[node];
        break :brk try self.assertToken(main_token, .identifier);
    };
    const identifier = ast.tokenSlice(identifier_token);

    var reference = Reference{
        .node = node,
        .token = identifier_token,
        .symbol = Symbol.Id.Optional.from(opts.symbol),
        .identifier = identifier,
        .scope = scope,
        .flags = flags,
    };

    var is_primitive = false;
    if (reference.symbol == .none) {
        // TODO: add primitives to the symbol table and bind them here.
        is_primitive = builtins.isPrimitiveType(identifier) or builtins.isPrimitiveValue(identifier);
        reference.flags.primitive = is_primitive;
    }

    const ref_id = try self._semantic.symbols.addReference(self._gpa, reference);
    if (opts.symbol == null and !is_primitive) try self._unresolved_references.append(self._gpa, ref_id);

    return ref_id;
}

fn resolveReferencesInCurrentScope(self: *SemanticBuilder) Allocator.Error!void {
    var stacka = std.heap.stackFallback(64, self._gpa);
    const stack = stacka.get();
    //
    const curr = self._unresolved_references.curr();
    const parent = self._unresolved_references.parent();
    const names = self.symbolTable().symbols.items(.name);
    const bindings: []const Symbol.Id = self.scopeTree().getBindings(self.currentScope());
    var references = self.symbolTable().references;
    // const ref_tokens: []TokenIndex = references.items(.identifier);
    const ref_names: []const string = references.items(.identifier);
    const ref_symbols: []Symbol.Id.Optional = self.symbolTable().references.items(.symbol);
    const symbol_refs = self.symbolTable().symbols.items(.references);

    const resolved_map = try stack.alloc(bool, curr.items.len);
    var num_resolved: usize = 0;
    @memset(resolved_map, false);
    defer stack.free(resolved_map);

    for (bindings) |binding| {
        const name: string = names[binding.int()];
        for (0..curr.items.len) |i| {
            if (resolved_map[i] or name.len == 0) continue;
            const ref_id: Reference.Id = curr.items[i];
            const ref = ref_id.int();
            const ref_name = ref_names[ref];
            {
                // hypothesis: we know identifiers always have a non-zero
                // length. By communicating this to the compiler, the `a.len ==
                // 0` check in `mem.eql` should be optimized out.
                @setRuntimeSafety(util.IS_DEBUG);
                assert(ref_name.len > 0);
            }

            // we resolved the reference :)
            if (mem.eql(u8, name, ref_name)) {
                num_resolved += 1;
                resolved_map[i] = true;
                // link ref -> symbol and symbol -> ref
                ref_symbols[ref] = binding.into(Symbol.Id.Optional);
                try symbol_refs[binding.int()].append(self._gpa, ref_id);
            }
        }
    }

    const num_unresolved = curr.items.len - num_resolved;
    if (num_unresolved > 0) {
        if (parent) |p| {
            try p.ensureUnusedCapacity(self._gpa, num_unresolved);
            for (0..curr.items.len) |i| {
                if (resolved_map[i]) continue;
                p.appendAssumeCapacity(curr.items[i]);
            }
            // only delete current frame when we can't move things to the parent. We
            // want the last frame to exist so we can move it to the list of
            // unresolved references in the symbol table
            curr.deinit(self._gpa);
            _ = self._unresolved_references.frames.pop();
        } else {
            const temp = try self._gpa.dupe(Reference.Id, curr.items);
            defer self._gpa.free(temp);
            var i: usize = 0;
            var j: usize = 0;
            while (i < temp.len) : (i += 1) {
                if (!resolved_map[i]) continue;
                curr.items[j] = temp[i];
                j += 1;
            }
        }
    } else {
        curr.deinit(self._gpa);
        _ = self._unresolved_references.frames.pop();
    }
}

const ReferenceStack = struct {
    frames: std.ArrayListUnmanaged(ReferenceIdList) = .{},

    const ReferenceIdList = std.ArrayListUnmanaged(Reference.Id);

    fn init(alloc: Allocator) Allocator.Error!ReferenceStack {
        var self: ReferenceStack = .{};
        try self.frames.ensureTotalCapacity(alloc, 16);

        return self;
    }

    /// current frame
    pub fn curr(self: *ReferenceStack) *ReferenceIdList {
        assert(self.len() > 0);
        return &self.frames.items[self.len() - 1];
    }

    /// parent frame. `null` when currently in root scope.
    pub fn parent(self: *ReferenceStack) ?*ReferenceIdList {
        return if (self.len() <= 1) null else &self.frames.items[self.len() - 2];
    }

    /// current number of frames
    inline fn len(self: ReferenceStack) usize {
        return self.frames.items.len;
    }

    fn enter(self: *ReferenceStack, alloc: Allocator) Allocator.Error!void {
        try self.frames.append(alloc, .{});
    }
    fn exit(self: *ReferenceStack, alloc: Allocator) void {
        var frame = self.frames.pop();
        frame.deinit(alloc);
    }

    /// Add an unresolved reference to the current frame
    fn append(self: *ReferenceStack, alloc: Allocator, ref: Reference.Id) Allocator.Error!void {
        try self.curr().append(alloc, ref);
    }

    fn deinit(self: *ReferenceStack, alloc: Allocator) void {
        for (0..self.frames.items.len) |i| {
            self.frames.items[i].deinit(alloc);
        }
        self.frames.deinit(alloc);
    }
};

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

/// Returns `token` if it has the expected tag, or `null` if it doesn't.
inline fn expectToken(self: *const SemanticBuilder, token: TokenIndex, comptime tag: Token.Tag) ?TokenIndex {
    return if (self.AST().tokens.items(.tag)[token] == tag) token else null;
}

/// Like `expectToken`, but returns an error if the token doesn't have the expected tag.
///
/// Token tag checks are treated like other runtime safety checks and are
/// disabled by `ReleaseFast`.
inline fn assertToken(self: *const SemanticBuilder, token: TokenIndex, comptime tag: Token.Tag) SemanticError!TokenIndex {
    if (comptime !util.RUNTIME_SAFETY) return token;
    return self.expectToken(token, tag) orelse switch (tag) {
        .identifier => SemanticError.MissingIdentifier,
        else => SemanticError.UnexpectedToken,
    };
}

// =========================================================================
// =========================== ERROR MANAGEMENT ============================
// =========================================================================

fn addAstError(self: *SemanticBuilder, ast: *const Ast, ast_err: Ast.Error) Allocator.Error!void {
    // error message
    const message: string = blk: {
        var msg: std.ArrayListUnmanaged(u8) = .{};
        defer msg.deinit(self._gpa);
        try ast.renderError(ast_err, msg.writer(self._gpa));
        break :blk try msg.toOwnedSlice(self._gpa);
    };
    errdefer self._gpa.free(message);

    var err = Error.new(message);
    errdefer err.deinit(self._gpa);

    // label where in the source the error occurred
    // TODO: render `ast_err.extra.expected_tag`
    {
        const byte_offset: Ast.ByteOffset = ast.tokens.items(.start)[ast_err.token];
        const loc = ast.tokenLocation(byte_offset, ast_err.token);
        const span = LabeledSpan{
            .span = .{ .start = @intCast(loc.line_start), .end = @intCast(loc.line_end) },
        };
        try err.labels.ensureTotalCapacityPrecise(self._gpa, 1);
        err.labels.appendAssumeCapacity(span);
    }

    err.code = "syntax error";
    if (self._source_code) |src| err.source = src.clone();
    if (self._source_path) |path| err.source_name = try self._gpa.dupe(u8, path);

    try self._errors.append(self._gpa, err);
}

/// Record an error encountered during parsing or analysis.
///
/// All parameters are borrowed. Errors own their data, so each parameter gets cloned onto the heap.
fn addError(self: *SemanticBuilder, message: string, labels: []Span, help: ?string) Allocator.Error!void {
    const alloc = self._errors.allocator;
    const heap_message = try alloc.dupeZ(u8, message);
    const heap_labels = try alloc.dupe(Span, labels);
    const heap_help = if (help) |h| alloc.dupeZ(h) else null;
    const err = try Error{
        .message = .{ .str = heap_message, .static = false },
        .labels = heap_labels,
        .help = heap_help,
    };
    try self._errors.append(err);
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

        const source = if (id == Semantic.ROOT_NODE_ID) "" else ast.getNodeSource(id);
        const loc = ast.tokenLocation(token_offset, main_token);
        const snippet =
            if (source.len > 48) mem.concat(
            self._gpa,
            u8,
            &[_]string{ source[0..32], " ... ", source[(source.len - 16)..source.len] },
        ) catch @panic("Out of memory") else source;
        print("  - [{d}, {d}:{d}] {any} - {s}\n", .{ id, loc.line, loc.column, tag, snippet });
        if (!mem.eql(u8, source, snippet)) {
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
        const i = id.int();
        const name = names[i];
        print("  - {d}: {s}\n", .{ i, name });
    }
}

fn printScopeStack(self: *const SemanticBuilder) void {
    @setCold(true);
    const scopes = &self._semantic.scopes;

    print("Scope stack:\n", .{});
    const scope_flags = scopes.scopes.items(.flags);
    for (self._scope_stack.items) |id| {
        // const flags = scopes.scopes.items[id].flags;
        print("  - {d}: (flags: {any})\n", .{ id, scope_flags[id.into(usize)] });
    }
}

const SemanticBuilder = @This();

const builtins = @import("builtins.zig");
const Semantic = @import("./Semantic.zig");
const Scope = Semantic.Scope;
const Symbol = Semantic.Symbol;
const NodeLinks = Semantic.NodeLinks;
const Reference = Semantic.Reference;

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Type = std.builtin.Type;

const assert = std.debug.assert;

const _ast = @import("ast.zig");
const Ast = _ast.Ast;
const full = Ast.full;
const Token = _ast.Token;
const Node = _ast.Node;
const NodeIndex = _ast.NodeIndex;
const RawToken = _ast.RawToken;
const TokenIndex = _ast.TokenIndex;

const Error = @import("../Error.zig");
const _source = @import("../source.zig");
const LabeledSpan = _source.LabeledSpan;
const Span = _source.Span;

const util = @import("util");
const IS_DEBUG = util.IS_DEBUG;
const string = util.string;
const stringSlice = util.stringSlice;

const t = std.testing;
test {
    t.refAllDecls(@import("test/symbol_ref_test.zig"));
    t.refAllDecls(@import("test/symbol_decl_test.zig"));
}
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
                const name = names[id.int()];
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
