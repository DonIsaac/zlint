// Important things I've learned about Zig's AST:
//
// For nodes:
// - tags .foo and .foo_semicolon are the same.
// - if there's a .foo and .foo_two tag, then
//   - .foo_two has its data in the `opt_node_and_opt_node` (or similar) Data variant
//   - .foo's data is in an `extra_range` variant that indexes into `ast.extra_data`.
//     That gets the variable-len list of child nodes.
//

const SemanticBuilder = @This();

_gpa: Allocator,
_arena: ArenaAllocator,

_source_code: ?_source.ArcStr = null,
_source_path: ?[]const u8 = null,

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
_scope_stack: std.ArrayList(Semantic.Scope.Id) = .{},
/// When entering an initialization container for a symbol, that symbol's ID
/// is pushed here. This lets us record members and exports.
_symbol_stack: std.ArrayList(Semantic.Symbol.Id) = .{},
_node_stack: std.ArrayList(NodeIndex) = .{},
/// References encountered but that could not be resolved. Includes references
/// that occur before symbol declaration, and we haven't seen the declaration yet.
/// After analysis, references in this list are to symbols not declared anywhere
/// in the source.
///
/// We try to resolve these each time a scope is exited.
_unresolved_references: ReferenceStack = .{},

_semantic: Semantic,
/// Errors encountered during parsing and analysis.
///
/// Errors in this list are allocated using this list's allocator.
_errors: std.ArrayList(Error) = .{},

/// The root node always has an index of 0. Since it is never referenced by other nodes,
/// the Zig team uses it to represent `null` without wasting extra memory.
const NULL_NODE: NodeIndex = .root;
const ROOT_SCOPE: Semantic.Scope.Id = .from(0);
// const BUILTIN_SCOPE: Semantic.Scope.Id = Semantic.BUILTIN_SCOPE_ID;

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
        // SAFETY: initialized after parsing
        ._semantic = undefined,
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
pub fn build(builder: *SemanticBuilder, source: [:0]const u8) SemanticError!Result {
    // NOTE: ast is moved
    const gpa = builder._gpa;
    const arena = builder._arena.allocator();
    var parse, const stats = try Semantic.Parse.build(arena, source);

    // Record parse errors
    if (parse.ast.errors.len > 0) {
        try builder._errors.ensureUnusedCapacity(builder._gpa, parse.ast.errors.len);
        for (parse.ast.errors) |ast_err| {
            // Not an error. TODO: verify this assumption
            if (ast_err.is_note) continue;
            try builder.addAstError(&parse.ast, ast_err);
        }
    }

    const node_count = parse.ast.nodes.len;
    const node_links = try NodeLinks.init(gpa, &parse.ast);
    assert(node_count == node_links.parents.items.len);
    assert(node_count == node_links.scopes.items.len);

    // reserve capacity for stacks
    try builder._scope_stack.ensureTotalCapacity(gpa, 8); // TODO: use stack fallback allocator?
    try builder._symbol_stack.ensureTotalCapacity(gpa, 8);
    // TODO: verify this hypothesis. What is the max node stack len while
    // building? (avg over a representative sample of real Zig files.)
    try builder._node_stack.ensureTotalCapacity(gpa, @max(node_count, 32) >> 2);

    builder._semantic = Semantic{
        .parse = parse,
        .node_links = node_links,
        ._arena = builder._arena,
        ._gpa = gpa,
    };
    errdefer builder._semantic.deinit();

    // TODO: collect data and approximate #symbols declared vs. #identifiers encountered
    // TODO: benchmark analysis with and without this
    try builder._semantic.symbols.symbols.ensureTotalCapacity(
        builder._gpa,
        stats.identifiers >> 1,
    );

    // Create root scope & symbol and push them onto their stacks. Also
    // pushes the root node. None of these are ever popped.
    try builder.enterRoot();
    builder.assertRoot(); // sanity check

    for (builder.AST().rootDecls()) |node| {
        try builder.visitNode(node);
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

// =========================================================================
// ================================= VISIT =================================
// =========================================================================

/// Visit an AST node.
///
/// Null and bounds checks are performed here, while actual logic is
/// handled by `visitNode`. This lets us inline checks within caller
/// functions, reducing unnecessary branching and stack pointer pushes.
fn visit(self: *SemanticBuilder, node_id: NodeIndex) SemanticError!void {
    if (node_id == NULL_NODE) return;
    if (@intFromEnum(node_id) >= self.AST().nodes.len) {
        @branchHint(.cold);
        return;
    }

    return self.visitNode(node_id);
}

/// Visit an optional node. Unwraps the OptionalIndex and visits if present.
fn visitOptional(self: *SemanticBuilder, opt: Node.OptionalIndex) SemanticError!void {
    if (opt.unwrap()) |node_id| return self.visit(node_id);
}

/// Like `visitOptional`, but turns off `read`/`write` reference flags and turns on `type`.
fn visitOptionalType(self: *SemanticBuilder, opt: Node.OptionalIndex) SemanticError!void {
    if (opt.unwrap()) |node_id| return self.visitType(node_id);
}

/// Visit a node in the AST. Do not call this directly, use `visit` instead.
fn visitNode(self: *SemanticBuilder, node_id: NodeIndex) SemanticError!void {
    const ast = self.AST();
    const tag: Ast.Node.Tag = ast.nodeTag(node_id);

    try self.enterNode(node_id);
    defer self.exitNode();

    switch (tag) {
        // root node is never referenced b/c of NULL_NODE check at function start
        .root => unreachable,
        // containers and container members
        // ```zig
        // const Foo = struct { // <-- visits struct/enum/union containers
        //   foo: u32,          // <-- container field declaration
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
            var buf: [2]NodeIndex = undefined;
            const container = ast.fullContainerDecl(&buf, node_id) orelse unreachable;
            return self.visitContainer(node_id, container);
        },

        // container field declarations
        .container_field => return self.visitContainerField(node_id, ast.containerField(node_id)),
        .container_field_align => return self.visitContainerField(node_id, ast.containerFieldAlign(node_id)),
        .container_field_init => return self.visitContainerField(node_id, ast.containerFieldInit(node_id)),

        // var/const declarations
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            const decl = ast.fullVarDecl(node_id) orelse unreachable;
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

        // function declarations
        .fn_decl => return self.visitFnDecl(node_id),
        .fn_proto => return self.visitFnProto(node_id, ast.fnProto(node_id)),
        .fn_proto_one => {
            var buf: [1]Node.Index = undefined;
            return self.visitFnProto(node_id, ast.fnProtoOne(&buf, node_id));
        },
        .fn_proto_simple => {
            var buf: [1]Node.Index = undefined;
            return self.visitFnProto(node_id, ast.fnProtoSimple(&buf, node_id));
        },
        .fn_proto_multi => return self.visitFnProto(node_id, ast.fnProtoMulti(node_id)),

        // function calls
        .call, .call_comma => return self.visitCall(node_id, ast.callFull(node_id)),
        .call_one, .call_one_comma => {
            var buf: [1]NodeIndex = undefined;
            if (IS_DEBUG) {
                util.assert(ast.fullCall(&buf, node_id) != null, "fullCall returned null for tag {any}", .{tag});
            }
            return self.visitCall(node_id, ast.callOne(&buf, node_id));
        },
        .builtin_call, .builtin_call_comma => return self.visitBuiltinCall(node_id, true),
        .builtin_call_two, .builtin_call_two_comma => return self.visitBuiltinCall(node_id, false),

        // control flow

        // loops
        .while_simple => return self.visitWhile(node_id, ast.whileSimple(node_id)),
        .while_cont => return self.visitWhile(node_id, ast.whileCont(node_id)),
        .@"while" => return self.visitWhile(node_id, ast.whileFull(node_id)),
        .for_simple => return self.visitFor(node_id, ast.forSimple(node_id)),
        .@"for" => return self.visitFor(node_id, ast.forFull(node_id)),

        // conditionals
        .if_simple => return self.visitIf(node_id, ast.ifSimple(node_id)),
        .@"if" => return self.visitIf(node_id, ast.ifFull(node_id)),
        .@"switch", .switch_comma => return self.visitSwitch(node_id, ast.switchFull(node_id)),
        .switch_case, .switch_case_inline, .switch_case_one, .switch_case_inline_one => {
            const case = ast.fullSwitchCase(node_id) orelse unreachable;
            return self.visitSwitchCase(node_id, case);
        },

        .@"catch" => return self.visitCatch(node_id),

        // blocks
        .block_two, .block_two_semicolon => {
            const first, const second = ast.nodeData(node_id).opt_node_and_opt_node;
            if (first.unwrap()) |s0| {
                if (second.unwrap()) |s1| {
                    const statements = [2]NodeIndex{ s0, s1 };
                    return self.visitBlock(&statements);
                } else {
                    const statements = [1]NodeIndex{s0};
                    return self.visitBlock(&statements);
                }
            } else {
                return self.visitBlock(&.{});
            }
        },
        .block, .block_semicolon => {
            const range = ast.nodeData(node_id).extra_range;
            const stmts = ast.extraDataSlice(range, Node.Index);
            return self.visitBlock(stmts);
        },

        .test_decl => {
            const prev = self.setScopeFlag(.s_comptime, false);
            defer self.restoreScopeFlag(.s_comptime, prev);
            self._next_block_scope_flags = .{ .s_test = true, .s_block = true };
            // TODO: record .s_test symbol references when test name is an `.identifier`
            return self.visit(ast.nodeData(node_id).opt_token_and_node[1]);
        },

        // pointers

        .anyframe_type => return self.visit(ast.nodeData(node_id).token_and_node[1]),
        .slice_open => return self.visitSlice(node_id, ast.sliceOpen(node_id)),
        .slice => return self.visitSlice(node_id, ast.slice(node_id)),
        .slice_sentinel => return self.visitSlice(node_id, ast.sliceSentinel(node_id)),
        .ptr_type,
        .ptr_type_sentinel,
        .ptr_type_aligned,
        .ptr_type_bit_range,
        => {
            const ptr = self.AST().fullPtrType(node_id) orelse @panic("expected node to be a ptr type");
            return self.visitPtrType(ptr);
        },

        // no child nodes
        .char_literal,
        .number_literal,
        .unreachable_literal,
        .string_literal,
        .anyframe_literal,
        .error_value,
        .enum_literal,
        // token_and_token; still no need to traverse
        .multiline_string_literal,
        => return,

        .error_set_decl => return self.visitErrorSetDecl(node_id),

        // TODO: asm support
        .@"asm", .asm_simple, .asm_output, .asm_input, .asm_legacy => return,

        .@"comptime" => {
            const prev_comptime = self.setScopeFlag(.s_comptime, true);
            defer self.restoreScopeFlag(.s_comptime, prev_comptime);

            return self.visit(ast.nodeData(node_id).node);
        },

        .grouped_expression,
        .unwrap_optional,
        => return self.visit(ast.nodeData(node_id).node_and_token[0]),
        .@"break" => return self.visitOptional(ast.nodeData(node_id).opt_token_and_opt_node[1]),
        .@"return" => return self.visitOptional(ast.nodeData(node_id).opt_node),
        .@"nosuspend",
        .@"suspend",
        .@"try",
        .@"resume",
        .address_of,
        .bit_not,
        .bool_not,
        .deref,
        .negation_wrap,
        .negation,
        .optional_type,
        .@"defer",
        => return self.visit(ast.nodeData(node_id).node),
        .@"continue" => return self.visitOptional(ast.nodeData(node_id).opt_token_and_opt_node[1]),
        .@"errdefer" => return self.visit(ast.nodeData(node_id).opt_token_and_node[1]),

        // binary ops — .node_and_node
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .merge_error_sets,
        .mul,
        .div,
        .mod,
        .array_mult,
        .mul_wrap,
        .mul_sat,
        .add,
        .sub,
        .array_cat,
        .add_wrap,
        .sub_wrap,
        .add_sat,
        .sub_sat,
        .shl,
        .shl_sat,
        .shr,
        .bit_and,
        .bit_xor,
        .bit_or,
        .@"orelse",
        .bool_and,
        .bool_or,
        .array_type,
        .array_access,
        .switch_range,
        .error_union,
        => {
            const left, const right = ast.nodeData(node_id).node_and_node;
            try self.visit(left);
            return self.visit(right);
        },

        // .node_and_opt_node
        .for_range => {
            const left, const right = ast.nodeData(node_id).node_and_opt_node;
            try self.visit(left);
            return self.visitOptional(right);
        },

        // .node_and_extra — visit the node child only
        .array_type_sentinel => return self.visit(ast.nodeData(node_id).node_and_extra[0]),
    }
}

/// Like `visit`, but turns off `read`/`write` reference flags and turns on `type`.
fn visitType(self: *SemanticBuilder, node_id: NodeIndex) callconv(util.@"inline") !void {
    const prev = self.takeReferenceFlags();
    defer self._curr_reference_flags = prev;
    self._curr_reference_flags.type = true;
    try self.visit(node_id);
}

fn visitRecursiveSlice(self: *SemanticBuilder, node_id: NodeIndex) callconv(util.@"inline") !void {
    const range = self.getNodeData(node_id).extra_range;
    const ast = self.AST();
    const children = ast.extraDataSlice(range, Node.Index);
    for (children) |child| {
        try self.visit(child);
    }
}

// TODO: inline after we're done debugging
fn visitBlock(self: *SemanticBuilder, statements: []const NodeIndex) !void {
    const NON_COMPTIME_BLOCKS: Scope.Flags = .{ .s_test = true, .s_block = true, .s_function = true };
    const is_root = self.currentScope() == ROOT_SCOPE;
    const was_comptime = self._curr_scope_flags.s_comptime;
    const is_comptime = was_comptime or (is_root and !self._curr_scope_flags.intersects(NON_COMPTIME_BLOCKS));

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
    const ast = self.AST();
    const tags: []const Token.Tag = ast.tokens.items(.tag);

    const main_token = ast.nodeMainToken(node);
    const container_tag = tags[main_token];
    const scope_flags: Scope.Flags, var symbol_flags: Symbol.Flags = switch (container_tag) {
        .keyword_enum => .{ .{ .s_enum = true }, .{ .s_enum = true } },
        .keyword_struct => .{ .{ .s_struct = true }, .{ .s_struct = true } },
        .keyword_union => .{ .{ .s_union = true }, .{ .s_union = true } },
        // e.g. opaque
        else => .{ .{}, .{} },
    };

    // const Foo = packed struct { ... }
    //             ^^^^^^
    if (container.layout_token) |layout_token| switch (tags[layout_token]) {
        // TODO: extern/packed enums are not allowed. Report it.
        .keyword_extern => symbol_flags.s_extern = true,
        else => {},
    };

    // packed structs, tagged unions, and enums may specify a representation type.
    // We need to record a type reference for it.
    // TODO: check if extern containers are banned from having a representation type.
    // if so, report it.
    if (container.ast.enum_token == null) {
        const maybe_ident = main_token + 2;
        if (tags[main_token + 1] == .l_paren and // w/o this, enum { x } triggers on x
            tags[maybe_ident] == .identifier and
            tags[maybe_ident + 1] != .period)
        {
            const prev = self.takeReferenceFlags();
            defer self._curr_reference_flags = prev;
            _ = try self.recordReference(.{
                .flags = .{ .type = true },
                .node = node,
                .token = maybe_ident,
            });
        }
    }

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
    const tags: []const Token.Tag = self.AST().tokens.items(.tag);

    var curr_tok = self.getNodeData(node_id).token_and_token[1];
    util.debugAssert(tags[curr_tok] == Token.Tag.r_brace, "error_set_decl rhs should be an rbrace token.", .{});
    curr_tok -= 1;

    try self.enterScope(.{ .flags = .{ .s_error = true } });
    defer self.exitScope();
    self.currentContainerSymbolFlags().s_error = true;

    while (true) : (curr_tok -= 1) {
        // NOTE: causes an out-of-bounds access in release builds, but the
        // assertion never fails in debug builds. TODO: investigate and report
        // to Zig team.
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
                @branchHint(.unlikely);
                // in debug builds we want to know if we're missing something or
                // handling errors incorrectly. in release mode we can safely
                // ignore it.
                util.debugAssert(false, "unexpected token in error container: {any}", .{tags[curr_tok]});
                break;
            },
        }
    }
}

// ======================= VARIABLE/FIELD DECLARATIONS ========================

/// Visit a container field (e.g. a struct property, enum variant, etc).
///
/// ```zig
/// const Foo = { // <-- Declared within this container's scope.
///   bar: u32    // <-- This is a container field. It is always Symbol.Visibility.public.
/// };            //     It is added to Foo's member table.
/// ```
fn visitContainerField(self: *SemanticBuilder, node_id: NodeIndex, field: full.ContainerField) !void {
    // This is a tuple field, e.g. `a` in `const Foo = struct { a, b };`
    if (field.ast.tuple_like and self.currentContainerSymbolFlags().s_struct) {
        if (comptime util.IS_DEBUG) assert(field.ast.align_expr == .none);

        try self.visitOptionalType(field.ast.type_expr);
        try self.visitOptional(field.ast.value_expr);
        return;
    }

    const main_token = self.AST().nodeMainToken(node_id);
    // main_token points to the field name
    // NOTE: container fields are always public
    const identifier = self.expectToken(main_token, .identifier);

    _ = try self.declareMemberSymbol(.{
        .identifier = identifier,
        .flags = .{
            .s_comptime = field.comptime_token != null,
            .s_struct = self.currentScope().eql(ROOT_SCOPE),
        },
    });
    const parent = self.currentContainerSymbolUnwrap().into(usize);

    try self.visitOptional(field.ast.align_expr);
    // NOTE: do not move this to the top of the function b/c for some reason it
    // causes a segfault in release builds
    const flags: []const Symbol.Flags = self.symbolTable().symbols.items(.flags);
    if (!flags[parent].s_enum) {
        try self.visitOptionalType(field.ast.type_expr);
    }
    try self.visitOptional(field.ast.value_expr);
}

/// Visit a variable declaration. Global declarations are visited
/// separately, because their lhs/rhs nodes and main token mean different
/// things.
fn visitVarDecl(self: *SemanticBuilder, node_id: NodeIndex, var_decl: full.VarDecl) !void {
    const ast = self.AST();
    const main_token: TokenIndex = ast.nodeMainToken(node_id);

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
        @branchHint(.unlikely); // most vars are not extern/export
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
    try self.visitOptionalType(var_decl.ast.type_node);

    try self.visitOptional(var_decl.ast.init_node);
}

// ================================ ASSIGNMENT =================================

fn visitAssignment(self: *SemanticBuilder, node_id: NodeIndex, tag: Node.Tag) SemanticError!void {
    const does_read_lhs = tag != .assign;
    const pair = self.getNodeData(node_id).node_and_node;
    const flags = self._curr_reference_flags;
    defer self._curr_reference_flags = flags;

    {
        self._curr_reference_flags.write = true;
        self._curr_reference_flags.read = does_read_lhs;
        try self.visit(pair[0]);
    }
    {
        self._curr_reference_flags.read = true;
        self._curr_reference_flags.write = false;
        self._curr_reference_flags.call = false;
        try self.visit(pair[1]);
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
    const token_tags: []Token.Tag = ast.tokens.items(.tag);
    const is_comptime = destructure.comptime_token != null;

    for (destructure.ast.variables) |var_id| {
        const main_token: TokenIndex = ast.nodeMainToken(var_id);
        if (ast.fullVarDecl(var_id)) |decl| {
            const identifier = try self.assertToken(main_token + 1, .identifier);

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
        } else {
            // Destructuring allows arbitrary lvalue expressions: identifiers (`_`, existing
            // names), field access, indexing, etc. Match plain `=` — LHS is a write, not a read.
            const flags = self._curr_reference_flags;
            defer self._curr_reference_flags = flags;
            self._curr_reference_flags.write = true;
            self._curr_reference_flags.read = false;
            try self.visit(var_id);
        }
    }
    try self.visit(destructure.ast.value_expr);
}

// ========================= VARIABLE/FIELD REFERENCES  ========================

fn visitIdentifier(self: *SemanticBuilder, node_id: NodeIndex) !void {
    const identifier = try self.assertToken(self.AST().nodeMainToken(node_id), .identifier);
    const identifier_name = self.tokenSlice(identifier);

    // I think we can do this? Not sure about `_` enum members, but those shouldn't
    // hit this path.
    if (identifier_name.len == 1 and identifier_name[0] == '_') return;

    const symbol = self._semantic.resolveBinding(
        self.currentScope(),
        identifier_name,
        .{ .exclude = .{ .s_member = true } },
    );

    _ = try self.recordReference(.{
        .node = node_id,
        .symbol = symbol,
        .token = identifier,
    });
}

fn visitFieldAccess(self: *SemanticBuilder, node_id: NodeIndex) callconv(util.@"inline") !void {
    // TODO: record references
    return self.visit(self.getNodeData(node_id).node_and_token[0]);
}

fn visitSlice(self: *SemanticBuilder, _: NodeIndex, slice: full.Slice) !void {
    const prev = self.takeReferenceFlags();
    defer self._curr_reference_flags = prev;
    self._curr_reference_flags.read = true;
    self._curr_reference_flags.write = false;
    self._curr_reference_flags.call = false;

    try self.visit(slice.ast.start);
    try self.visitOptional(slice.ast.end);
    try self.visitOptional(slice.ast.sentinel);
    try self.visit(slice.ast.sliced);
}

fn visitPtrType(self: *SemanticBuilder, ptr: full.PtrType) !void {
    try self.visitOptional(ptr.ast.align_node);
    try self.visitOptional(ptr.ast.addrspace_node);
    try self.visitOptional(ptr.ast.sentinel);
    try self.visitOptional(ptr.ast.bit_range_start);
    try self.visitOptional(ptr.ast.bit_range_end);
    try self.visit(ptr.ast.child_type);
}

// =============================================================================

fn visitArrayInit(self: *SemanticBuilder, _: NodeIndex, arr: full.ArrayInit) callconv(util.@"inline") !void {
    try self.visitOptionalType(arr.ast.type_expr);
    for (arr.ast.elements) |el| {
        try self.visit(el);
    }
}

fn visitStructInit(self: *SemanticBuilder, _: NodeIndex, @"struct": full.StructInit) callconv(util.@"inline") !void {
    try self.visitOptional(@"struct".ast.type_expr);
    for (@"struct".ast.fields) |field| {
        try self.visit(field);
    }
}
// ============================== STATEMENTS ===============================

fn visitWhile(self: *SemanticBuilder, _: NodeIndex, while_stmt: full.While) callconv(util.@"inline") !void {
    try self.visit(while_stmt.ast.cond_expr);
    try self.visitOptional(while_stmt.ast.cont_expr);
    try self.visit(while_stmt.ast.then_expr);
    try self.visitOptional(while_stmt.ast.else_expr);
}

fn visitFor(self: *SemanticBuilder, node: NodeIndex, for_stmt: full.For) callconv(util.@"inline") !void {
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
    try self.visitOptional(for_stmt.ast.else_expr);
}

fn visitIf(self: *SemanticBuilder, _: NodeIndex, if_stmt: full.If) callconv(util.@"inline") !void {
    const ast = self.AST();
    const tags = ast.tokens.items(.tag);

    try self.visit(if_stmt.ast.cond_expr);

    {
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
        try self.enterScope(.{});
        defer self.exitScope();
        defer self._next_block_scope_flags = .{};

        if (if_stmt.error_token) |payload| {
            if (if_stmt.ast.else_expr.unwrap()) |else_expr| {
                const identifier = if (tags[payload] == .identifier) payload else payload + 1;
                if (tags[identifier] != .identifier) return error.MissingIdentifier;
                _ = try self.declareSymbol(.{
                    .declaration_node = else_expr,
                    .identifier = identifier,
                    .flags = .{
                        .s_payload = true,
                        .s_const = true,
                    },
                });
            }
        }

        try self.visitOptional(if_stmt.ast.else_expr);
    }
}

fn visitSwitch(self: *SemanticBuilder, _: NodeIndex, @"switch": full.Switch) !void {
    const ast = @"switch".ast;
    const tree = self.AST();

    try self.visitNode(ast.condition);
    try self.enterScope(.{});
    defer self.exitScope();

    for (ast.cases) |case_id| {
        const case = tree.fullSwitchCase(case_id) orelse unreachable;
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
    const pair = self.getNodeData(node_id).node_and_node;

    try self.visit(pair[0]);

    const fallback_first = ast.firstToken(pair[1]);
    const main_token = ast.nodeMainToken(node_id);

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
    return self.visit(pair[1]);
}

fn visitFnProto(self: *SemanticBuilder, _: NodeIndex, fn_proto: full.FnProto) !void {
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
        try self.visitOptional(fn_proto.ast.return_type);
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
            const prev_tag: Token.Tag = tags[name_token - 1];
            _ = try self.declareSymbol(.{
                .declaration_node = node_id,
                .identifier = name_token,
                .flags = .{
                    .s_comptime = prev_tag == .keyword_comptime,
                    .s_fn_param = true,
                    .s_const = true, // function parameters are always implicitly const
                },
            });
        }

        if (param.type_expr) |type_node| {
            try self.visit(type_node);
        }
    }
}

fn visitFnDecl(self: *SemanticBuilder, node_id: NodeIndex) callconv(util.@"inline") !void {
    var buf: [1]NodeIndex = undefined;
    const ast = self.AST();
    const fn_data = ast.nodeData(node_id).node_and_node;
    const proto = ast.fullFnProto(&buf, fn_data[0]) orelse unreachable;
    const visibility = if (proto.visib_token == null) Symbol.Visibility.private else Symbol.Visibility.public;
    // TODO: bound name vs escaped name
    const debug_name: ?[]const u8 = if (proto.name_token == null) "<anonymous fn>" else null;

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

    var fn_signature_implies_comptime = if (proto.ast.return_type.unwrap()) |rt|
        mem.eql(u8, ast.getNodeSource(rt), "type")
    else
        false;
    if (!fn_signature_implies_comptime) {
        for (proto.ast.params) |param_id| {
            if (ast.nodeTag(param_id) == .@"comptime") {
                fn_signature_implies_comptime = true;
                break;
            }
        }
    }

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
        try self.visitOptional(proto.ast.return_type);
    }

    self._next_block_scope_flags.s_function = true;
    try self.visit(fn_data[1]);
    util.assert(
        self._next_block_scope_flags.eql(.{}),
        "Function body scope flags were not reset. This means the body was not a block node.",
        .{},
    );
}

/// Visit a function call. Does not visit calls to builtins
fn visitCall(self: *SemanticBuilder, _: NodeIndex, call: full.Call) !void {
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

fn visitBuiltinCall(self: *SemanticBuilder, node: NodeIndex, comptime is_slice: bool) !void {
    const builtin = try self.assertToken(self.AST().nodeMainToken(node), .builtin);
    const builtin_name = self.tokenSlice(builtin);
    if (!is_slice and mem.eql(u8, builtin_name, "@import")) {
        try self.recordImport(node);
    }

    if (is_slice) {
        return self.visitRecursiveSlice(node);
    } else {
        const pair = self.getNodeData(node).opt_node_and_opt_node;
        try self.visitOptional(pair[0]);
        try self.visitOptional(pair[1]);
    }
}

// =========================================================================
// ======================== SCOPE/SYMBOL MANAGEMENT ========================
// =========================================================================

fn enterRoot(self: *SemanticBuilder) !void {
    @branchHint(.cold);

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
    util.assert(
        root_scope_id == Semantic.ROOT_SCOPE_ID,
        "Creating root scope returned id {d} which is not the expected root id ({d})",
        .{ root_scope_id, Semantic.ROOT_SCOPE_ID },
    );

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
    util.assert(
        root_symbol_id.int() == 0,
        "Creating root symbol returned id {d} which is not the expected root id (0)",
        .{root_symbol_id},
    );
    try self.enterContainerSymbol(root_symbol_id);
}

/// Panic if we're not currently within the root scope and node.
///
/// This function gets erased in Release* builds.
inline fn assertRoot(self: *const SemanticBuilder) void {
    if (!util.IS_DEBUG) return;

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
    self.links().setParent(node_id, curr_node);
    self.links().setScope(node_id, curr_scope);
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
    comptime assert(IS_DEBUG);
    var is_loop = false;
    for (self._node_stack.items) |id| {
        if (node_id == id) {
            is_loop = true;
            break;
        }
    }
    self.assertCtx(!is_loop, "Invariant violation: Node {d} is already on the stack", .{@intFromEnum(node_id)});
}

inline fn enterContainerSymbol(self: *SemanticBuilder, symbol_id: Symbol.Id) Allocator.Error!void {
    try self._symbol_stack.append(self._gpa, symbol_id);
}

/// Pop the most recent container symbol from the stack. Panics if the symbol stack is empty.
inline fn exitContainerSymbol(self: *SemanticBuilder) void {
    _ = self._symbol_stack.pop().?;
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
    debug_name: ?[]const u8 = null,
    /// Visibility to external code. Defaults to public.
    visibility: Symbol.Visibility = .public,
    flags: Symbol.Flags = .{},
    /// The scope where the symbol is declared. Defaults to the current scope.
    scope_id: ?Scope.Id = null,
};

/// Create and bind a symbol to the current scope and container (parent) symbol.
///
/// Panics if the parent is a member symbol.
fn bindSymbol(self: *SemanticBuilder, opts: DeclareSymbol) Allocator.Error!Symbol.Id {
    const symbol_id = try self.declareSymbol(opts);
    if (self.currentContainerSymbol()) |container_id| {
        assert(!self.symbolTable().symbols.items(.flags)[container_id.int()].s_member);
        if (opts.flags.s_member) {
            try self.symbolTable().addMember(self._gpa, symbol_id, container_id);
        } else {
            try self.symbolTable().addExport(self._gpa, symbol_id, container_id);
        }
    }

    return symbol_id;
}

/// Declare a new symbol in the current scope/AST node and record it as a member to
/// the most recent container symbol. Returns the new member symbol's ID.
fn declareMemberSymbol(
    self: *SemanticBuilder,
    opts: DeclareSymbol,
) Allocator.Error!Symbol.Id {
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
fn declareSymbol(
    self: *SemanticBuilder,
    opts: DeclareSymbol,
) callconv(util.@"inline") Allocator.Error!Symbol.Id {
    const scope = opts.scope_id orelse self.currentScope();
    const name = if (opts.identifier) |ident| self.tokenSlice(ident) else null;
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
    if (opts.identifier) |identifier| {
        try self.links().symbols.put(self._gpa, identifier, symbol_id);
    }
    return symbol_id;
}

// =========================== Subsection: References ==========================

inline fn takeReferenceFlags(self: *SemanticBuilder) Reference.Flags {
    const flags = self._curr_reference_flags;
    self._curr_reference_flags = .{};
    return flags;
}

const CreateReference = struct {
    /// Defaults to current node
    node: ?NodeIndex = null,
    /// Defaults to `.main_token` for the `node`, which must be a `.identifier`
    /// token. No checks are performed when `token` is provided.
    token: ?TokenIndex = null,
    /// Defaults to current scope
    scope: ?Scope.Id = null,
    /// If `null`, will be added to unresolved reference list. The builder will
    /// attempt to resolve it later, as it progresses with the walk.
    symbol: ?Symbol.Id = null,
    /// Merged with current reference flags
    flags: Reference.Flags = .{},
};

fn recordReference(self: *SemanticBuilder, opts: CreateReference) SemanticError!Reference.Id {
    const ast = self.AST();
    const node = opts.node orelse self.currentNode();
    const scope = opts.scope orelse self.currentScope();
    const flags = opts.flags.merge(self._curr_reference_flags);
    const identifier_token: TokenIndex = opts.token orelse brk: {
        break :brk try self.assertToken(ast.nodeMainToken(node), .identifier);
    };
    const identifier = self.tokenSlice(identifier_token);

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
    const ref_names: []const []const u8 = references.items(.identifier);
    const ref_symbols: []Symbol.Id.Optional = self.symbolTable().references.items(.symbol);
    const symbol_refs = self.symbolTable().symbols.items(.references);

    const resolved_map = try stack.alloc(bool, curr.items.len);
    var num_resolved: usize = 0;
    @memset(resolved_map, false);
    defer stack.free(resolved_map);

    for (bindings) |binding| {
        const name: []const u8 = names[binding.int()];
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
            const last = self._unresolved_references.frames.pop();
            assert(last != null);
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
            curr.items.len = j;
        }
    } else {
        curr.deinit(self._gpa);
        _ = self._unresolved_references.frames.pop();
    }
}

// =========================================================================
// ================================ MODULES ================================
// =========================================================================

fn recordImport(self: *SemanticBuilder, node: NodeIndex) Allocator.Error!void {
    const ast = self.AST();

    const specifier_opt: Node.OptionalIndex = ast.nodeData(node).opt_node_and_opt_node[0];
    const specifier_node: NodeIndex = specifier_opt.unwrap() orelse return;
    if (ast.nodeTag(specifier_node) != .string_literal) {
        @branchHint(.cold);
        var e = Error.newStatic("@import specifiers must be string literals.");
        const loc: Token.Loc = self._semantic.tokens().items(.loc)[ast.nodeMainToken(specifier_node)];
        try e.labels.append(self._gpa, LabeledSpan.unlabeled(@intCast(loc.start), @intCast(loc.end)));
        try self._errors.append(self._gpa, e);
    }

    var specifier = self.tokenSlice(ast.nodeMainToken(specifier_node));
    specifier = std.mem.trim(u8, specifier, "\"");
    const is_file = specifier.len > 4 and specifier[specifier.len - 4] == '.';
    try self._semantic.modules.imports.append(self._gpa, ModuleRecord.ImportEntry{
        .specifier = specifier,
        .node = node,
        .kind = if (is_file) .file else .module,
    });
}

// =========================================================================
// ============================ RANDOM GETTERS =============================
// =========================================================================

/// Shorthand for getting the AST. Must be caps to avoid shadowing local
/// `ast` declarations.
inline fn AST(self: *const SemanticBuilder) *const Ast {
    return &self._semantic.parse.ast;
}

/// Shorthand for getting the symbol table.
inline fn symbolTable(self: *SemanticBuilder) *Symbol.Table {
    return &self._semantic.symbols;
}

/// Shorthand for getting the scope tree.
inline fn scopeTree(self: *SemanticBuilder) *Scope.Tree {
    return &self._semantic.scopes;
}

inline fn links(self: *SemanticBuilder) *NodeLinks {
    return &self._semantic.node_links;
}

fn tokenSlice(self: *const SemanticBuilder, token: TokenIndex) []const u8 {
    return self._semantic.tokenSlice(token);
}

inline fn getNodeData(self: *const SemanticBuilder, node_id: NodeIndex) Node.Data {
    return self.AST().nodeData(node_id);
}

/// Get a node by its ID.
///
/// ## Panics
/// - If attempting to access the root node (which acts as null).
/// - If `node_id` is out of bounds.
inline fn getNode(self: *const SemanticBuilder, node_id: NodeIndex) Node {
    if (node_id == .root) @panic("attempted to access null node");
    assert(@intFromEnum(node_id) < self.AST().nodes.len);

    return self.AST().nodes.get(@intFromEnum(node_id));
}

/// Get a node by its ID, returning `null` if its the root node (which acts as null).
///
/// ## Panics
/// - If `node_id` is out of bounds.
inline fn maybeGetNode(self: *const SemanticBuilder, node_id: NodeIndex) ?Node {
    {
        if (node_id == .root) return null;
        const len = self.AST().nodes.len;
        self.assertCtx(
            @intFromEnum(node_id) < len,
            "Cannot get node: id {d} is out of bounds ({d})",
            .{ @intFromEnum(node_id), len },
        );
    }

    return self.AST().nodes.get(@intFromEnum(node_id));
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
    @branchHint(.cold);
    const message: []u8 = blk: {
        var allocating = std.Io.Writer.Allocating.init(self._gpa);
        defer allocating.deinit();
        ast.renderError(ast_err, &allocating.writer) catch break :blk &.{};
        break :blk allocating.toOwnedSlice() catch break :blk &.{};
    };
    errdefer self._gpa.free(message);

    var err = Error.new(message, self._gpa);
    errdefer err.deinit(self._gpa);

    // label where in the source the error occurred
    // TODO: render `ast_err.extra.expected_tag`
    {
        const byte_offset: Ast.ByteOffset = ast.tokens.items(.start)[ast_err.token];
        const loc = ast.tokenLocation(byte_offset, ast_err.token);
        const span = LabeledSpan.unlabeled(@intCast(loc.line_start), @intCast(loc.line_end));
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
fn addError(self: *SemanticBuilder, message: []const u8, labels: []Span, help: ?[]const u8) Allocator.Error!void {
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
    @branchHint(.cold);
    const ast = self.AST();

    print("Node stack:\n", .{});
    for (self._node_stack.items) |id| {
        const tag: Node.Tag = ast.nodeTag(id);
        const main_token = ast.nodeMainToken(id);
        const token_offset = ast.tokens.get(main_token).start;

        const source = if (id == Semantic.ROOT_NODE_ID) "" else ast.getNodeSource(id);
        const loc = ast.tokenLocation(token_offset, main_token);
        const snippet =
            if (source.len > 128) mem.concat(
                self._gpa,
                u8,
                &[_][]const u8{
                    std.mem.trim(u8, source[0..64], &std.ascii.whitespace),
                    " ... ",
                    std.mem.trim(u8, source[(source.len - 64)..source.len], &std.ascii.whitespace),
                },
            ) catch @panic("Out of memory") else source;
        print("  - [{d}, {d}:{d}] {any} - {s}\n", .{ @intFromEnum(id), loc.line, loc.column, tag, snippet });
        if (!mem.eql(u8, source, snippet)) {
            self._gpa.free(snippet);
        }
    }
}

fn printSymbolStack(self: *const SemanticBuilder) void {
    @branchHint(.cold);
    const symbols = &self._semantic.symbols;
    const names: [][]const u8 = symbols.symbols.items(.name);

    print("Symbol stack:\n", .{});
    for (self._symbol_stack.items) |id| {
        const i = id.int();
        const name = names[i];
        print("  - {d}: {s}\n", .{ i, name });
    }
}

fn printScopeStack(self: *const SemanticBuilder) void {
    @branchHint(.cold);
    const scopes = &self._semantic.scopes;

    print("Scope stack:\n", .{});
    const scope_flags = scopes.scopes.items(.flags);
    for (self._scope_stack.items) |id| {
        // const flags = scopes.scopes.items[id].flags;
        print("  - {d}: (flags: {any})\n", .{ id, scope_flags[id.into(usize)] });
    }
}

const builtins = @import("builtins.zig");
const Semantic = @import("../Semantic.zig");
const Scope = Semantic.Scope;
const Symbol = Semantic.Symbol;
const NodeLinks = Semantic.NodeLinks;
const Reference = Semantic.Reference;
const ReferenceStack = @import("ReferenceStack.zig");
const ModuleRecord = Semantic.ModuleRecord;

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;

const tokenizer = @import("tokenizer.zig");
const Token = tokenizer.Token;

const _ast = @import("ast.zig");
const Ast = _ast.Ast;
const full = Ast.full;
const Node = _ast.Node;
const NodeIndex = _ast.NodeIndex;
const TokenIndex = _ast.TokenIndex;

const Error = @import("../Error.zig");
const _source = @import("../source.zig");
const _span = @import("../span.zig");
const LabeledSpan = _span.LabeledSpan;
const Span = _span.Span;

const util = @import("util");
const IS_DEBUG = util.IS_DEBUG;

const t = std.testing;
test {
    t.refAllDecls(@import("test/modules_test.zig"));
    t.refAllDecls(@import("test/scope_flags_test.zig"));
    t.refAllDecls(@import("test/scopes_test.zig"));
    t.refAllDecls(@import("test/symbol_decl_test.zig"));
    t.refAllDecls(@import("test/symbol_ref_test.zig"));
    t.refAllDecls(@import("test/members_and_exports_test.zig"));
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
