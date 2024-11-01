//! semantic analysis of a zig AST.
//!
//! We are intentionally not using Zig's AIR. That format strips away dead
//! code, which may be in the process of being authored. Instead, we perform
//! our own minimalist semantic analysis of an entire zig program.
//!
//! Additionally, we're avoiding an SoA (struct of arrays) format for now. Zig
//! (and many other parsers/analysis tools) use this to great perf advantage.
//! However, it sucks to work with when writing rules. We opt for simplicity to
//! reduce cognitive load and make contributing rules easier.
//!
//! Throughout this file you'll see mentions of a "program". This does not mean
//! an entire linked binary or library; rather it refers to a single parsed
//! file.

pub const Builder = struct {
    _gpa: Allocator,
    _arena: ArenaAllocator,
    _curr_scope_id: Semantic.Scope.Id = 0,
    _curr_symbol_id: ?Semantic.Symbol.Id = null,
    _scope_stack: std.ArrayListUnmanaged(Semantic.Scope.Id),
    /// When entering an initialization container for a symbol, that symbol's ID
    /// is pushed here. This lets us record members and exports.
    _symbol_stack: std.ArrayListUnmanaged(Semantic.Symbol.Id),
    /// SAFETY: initialized after parsing. Same safety rationale as _root_scope.
    _semantic: Semantic = undefined,
    /// Errors encountered during parsing and analysis.
    ///
    /// Errors in this list are allocated using this list's allocator.
    _errors: std.ArrayListUnmanaged(Error),

    pub fn build(gpa: Allocator, source: stringSlice) !Result {
        var builder = try Builder.init(gpa);
        defer builder.deinit();
        // NOTE: ast is moved
        const ast = try builder.parse(source);
        builder._semantic = Semantic{
            .ast = ast,
            ._arena = builder._arena,
            ._gpa = gpa,
        };
        errdefer builder._semantic.deinit();

        // initialize root scope
        try builder.enterRootScope();
        builder.assertRootScope(); // sanity check

        // Zig guarantees that the root node ID is 0. We should be careful- they may decide to change this contract.
        if (builtin.mode == .Debug) {
            print("number of nodes: {d}\n", .{builder._semantic.ast.nodes.len});
            var i: usize = 0;
            while (i < builder._semantic.ast.tokens.len) {
                const tok = builder._semantic.ast.tokens.get(i);
                print("token ({d}): {any}\n", .{ i, tok });
                i += 1;
            }
            print("\n", .{});
        }

        for (builder._semantic.ast.rootDecls()) |node| {
            builder.visitNode(node) catch |e| return e;
            builder.assertRootScope();
        }

        return Result.new(builder._gpa, builder._semantic, builder._errors);
    }

    fn init(gpa: Allocator) !Builder {
        var scope_stack: std.ArrayListUnmanaged(Semantic.Scope.Id) = .{};
        try scope_stack.ensureUnusedCapacity(gpa, 8);
        var symbol_stack: std.ArrayListUnmanaged(Semantic.Symbol.Id) = .{};
        try symbol_stack.ensureUnusedCapacity(gpa, 8);

        return Builder{ ._gpa = gpa, ._arena = ArenaAllocator.init(gpa), ._scope_stack = scope_stack, ._symbol_stack = symbol_stack, ._errors = .{} };
    }

    pub fn deinit(self: *Builder) void {
        self._scope_stack.deinit(self._gpa);
        self._symbol_stack.deinit(self._gpa);
    }

    fn parse(self: *Builder, source: stringSlice) !Ast {
        const ast = try Ast.parse(self._arena.allocator(), source, .zig);

        // Record parse errors
        if (ast.errors.len != 0) {
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

    const NULL_NODE: NodeIndex = 0;

    fn visitNode(self: *Builder, node_id: NodeIndex) anyerror!void {
        // when lhs/rhs are 0 (root node), it means `null`
        if (node_id == NULL_NODE) return;
        // Seeing this happen a log, needs debugging.
        if (IS_DEBUG and node_id >= self.AST().nodes.len) {
            print("ERROR: node ID out of bounds ({d})\n", .{node_id});
            return;
        }

        const tag: Ast.Node.Tag = self._semantic.ast.nodes.items(.tag)[node_id];
        switch (tag) {
            .root => unreachable, // root node is never referenced.
            // ```zig
            // const Foo = struct { // <-- visits struct/enum/union containers
            // };
            // ```
            .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing => {
                var buf: [2]u32 = undefined;
                const container = self.AST().fullContainerDecl(&buf, node_id) orelse unreachable;
                return self.visitContainer(node_id, container);
            },
            .container_field, .container_field_align, .container_field_init => {
                const field = self.AST().fullContainerField(node_id) orelse unreachable;
                return self.visitContainerField(node_id, field);
            },
            .global_var_decl => {
                const decl = self.AST().fullVarDecl(node_id) orelse unreachable;
                self.visitGlobalVarDecl(node_id, decl);
            },
            .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const decl = self.AST().fullVarDecl(node_id) orelse unreachable;
                return self.visitVarDecl(node_id, decl);
            },
            // .@"usingnamespace" => self.visitUsingNamespace(node),
            // else => std.debug.panic("unimplemented node tag: {any}", .{tag}),
            else => return self.visitRecursive(self.getNode(node_id)),
        }
    }

    /// Basic lhs/rhs traversal. This is just a shorthand.
    inline fn visitRecursive(self: *Builder, node: Node) !void {
        try self.visitNode(node.data.lhs);
        try self.visitNode(node.data.rhs);
    }

    fn visitContainer(self: *Builder, _: NodeIndex, container: Ast.full.ContainerDecl) !void {
        try self.enterScope(.{ .s_block = true, .s_enum = container.ast.enum_token != null });
        defer self.exitScope();
        for (container.ast.members) |member| {
            if (member > self.AST().nodes.len) {
                print("ERROR: member node ID out of bounds ({d})\n", .{member});
                continue;
            }
            try self.visitNode(member);
        }
    }

    /// Visit a container field (e.g. a struct property, enum variant, etc).
    ///
    /// ```zig
    /// const Foo = { // <-- Declared within this container's scope.
    ///   bar: u32    // <-- This is a container field. It is always Symbol.Visibility.public.
    /// };            //     It is added to Foo's member table.
    /// ```
    fn visitContainerField(self: *Builder, node_id: NodeIndex, field: Ast.full.ContainerField) !void {
        const main_token = self.AST().nodes.items(.main_token)[node_id];
        // main_token points to the field name
        const identifier = self.getIdentifier(main_token);
        const flags = Symbol.Flags{ .s_comptime = field.comptime_token != null, .s_member = true };
        // NOTE: container fields are always public
        // TODO: record type annotations
        _ = try self.declareMemberSymbol(node_id, identifier, .public, flags);
        if (field.ast.value_expr != NULL_NODE) {
            try self.visitNode(field.ast.value_expr);
        }
    }

    fn visitGlobalVarDecl(self: *Builder, node_id: NodeIndex, var_decl: Ast.full.VarDecl) void {
        _ = self;
        _ = node_id;
        _ = var_decl;
        @panic("todo: visitGlobalVarDecl");
    }

    /// Visit a variable declaration. Global declarations are visited
    /// separately, because their lhs/rhs nodes and main token mean different
    /// things.
    fn visitVarDecl(self: *Builder, node_id: NodeIndex, var_decl: Ast.full.VarDecl) !void {
        const node = self.getNode(node_id);
        // main_token points to `var`, `const` keyword. `.identifier` comes immediately afterwards
        const identifier: string = self.getIdentifier(node.main_token + 1);
        const flags = Symbol.Flags{ .s_comptime = var_decl.comptime_token != null };
        const visibility = if (var_decl.visib_token == null) Symbol.Visibility.private else Symbol.Visibility.public;
        const symbol_id = try self.declareSymbol(node_id, identifier, visibility, flags);
        try self.enterContainerSymbol(symbol_id);
        defer self.exitContainerSymbol();

        if (builtin.mode == .Debug) {
            const main = self.getToken(node.main_token);
            const lhs = self.maybeGetNode(node.data.lhs);
            const rhs = self.maybeGetNode(node.data.rhs);

            std.debug.print("node ({d}): {any}\n", .{ node_id, node });
            std.debug.print("main: {any}\n", .{main});
            std.debug.print("lhs: {any}\n", .{lhs});
            std.debug.print("rhs: {any}\n", .{rhs});
            std.debug.print("{any}\n\n", .{var_decl});
        }
        if (var_decl.ast.init_node != NULL_NODE) {
            assert(var_decl.ast.init_node < self.AST().nodes.len);
            try self.visitNode(var_decl.ast.init_node);
        }

        // return self.visitRecursive(node);
    }

    // =========================================================================
    // ======================== SCOPE/SYMBOL MANAGEMENT ========================
    // =========================================================================

    // NOTE: root scope is entered differently to avoid unnecessary parent-null
    // checks. Parent is only ever null for root scopes.

    inline fn enterRootScope(self: *Builder) !void {
        assert(self._scope_stack.items.len == 0);
        const root_scope = try self._semantic.scopes.addScope(self._gpa, null, .{ .s_top = true });
        assert(root_scope.id == 0);
        // Builder.init() allocates enough space for 8 scopes.
        self._scope_stack.appendAssumeCapacity(root_scope.id);
    }

    fn enterScope(self: *Builder, flags: Scope.Flags) !void {
        print("entering scope\n", .{});
        const parent_id = self._scope_stack.getLast(); // panics if stack is empty
        const scope = try self._semantic.scopes.addScope(self._gpa, parent_id, flags);
        try self._scope_stack.append(self._gpa, scope.id);
    }

    inline fn exitScope(self: *Builder) void {
        print("exiting scope\n", .{});
        assert(self._scope_stack.items.len > 1); // cannot pop root scope
        _ = self._scope_stack.pop();
    }

    inline fn currentScope(self: *const Builder) Scope.Id {
        assert(self._scope_stack.items.len != 0);
        return self._scope_stack.getLast();
    }

    fn assertRootScope(self: *const Builder) void {
        assert(self._scope_stack.items.len == 1);
        assert(self._scope_stack.items[0] == 0);
    }

    fn enterContainerSymbol(self: *Builder, symbol_id: Symbol.Id) !void {
        try self._symbol_stack.append(self._gpa, symbol_id);
    }

    fn exitContainerSymbol(self: *Builder) void {
        // NOTE: asserts stack is not empty
        _ = self._symbol_stack.pop();
    }

    fn currentContainerSymbol(self: *const Builder) ?Symbol.Id {
        return self._symbol_stack.getLastOrNull();
    }

    fn currentContainerSymbolUnwrap(self: *const Builder) Symbol.Id {
        return self._symbol_stack.getLast();
    }

    /// Declare a new symbol in the current scope and record it as a member to
    /// the most recent container symbol. Returns the new member symbol's ID.
    fn declareMemberSymbol(self: *Builder, declaration_node: Ast.Node.Index, name: string, visibility: Symbol.Visibility, flags: Symbol.Flags) !Symbol.Id {
        const member_symbol_id = try self.declareSymbol(declaration_node, name, visibility, flags);
        const container_symbol_id = self.currentContainerSymbolUnwrap();
        assert(!self._semantic.symbols.get(container_symbol_id).flags.s_member);
        try self._semantic.symbols.addMember(self._gpa, member_symbol_id, container_symbol_id);
        return member_symbol_id;
    }

    /// Declare a symbol in the current scope.
    inline fn declareSymbol(self: *Builder, declaration_node: Ast.Node.Index, name: string, visibility: Symbol.Visibility, flags: Symbol.Flags) !Symbol.Id {
        const symbol = try self._semantic.symbols.addSymbol(self._gpa, declaration_node, name, self.currentScope(), visibility, flags);
        return symbol.id;
    }

    // =========================================================================
    // ============================ RANDOM GETTERS =============================
    // =========================================================================

    inline fn AST(self: *const Builder) *const Ast {
        return &self._semantic.ast;
    }

    /// Get a node by its ID.
    ///
    /// ## Panics
    /// - If attempting to access the root node (which acts as null).
    /// - If `node_id` is out of bounds.
    inline fn getNode(self: *const Builder, node_id: NodeIndex) Node {
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
    inline fn maybeGetNode(self: *const Builder, node_id: NodeIndex) ?Node {
        if (node_id == 0) return null;
        assert(node_id < self.AST().nodes.len);

        return self.AST().nodes.get(node_id);
    }

    inline fn getToken(self: *const Builder, token_id: TokenIndex) RawToken {
        assert(token_id < self.AST().tokens.len);

        const t = self.AST().tokens.get(token_id);
        return .{
            .tag = t.tag,
            .start = t.start,
        };
    }

    /// Get an identifier name from an `.identifier` token.
    fn getIdentifier(self: *Builder, token_id: Ast.TokenIndex) string {
        const ast = self.AST();

        if (builtin.mode == .Debug) {
            const tag = ast.tokens.items(.tag)[token_id];
            assert(tag == .identifier);
        }

        const slice = ast.tokenSlice(token_id);
        return slice;
    }

    // =========================================================================
    // =========================== ERROR MANAGEMENT ============================
    // =========================================================================

    fn addAstError(self: *Builder, ast: *const Ast, ast_err: Ast.Error) !void {
        var msg: std.ArrayListUnmanaged(u8) = .{};
        defer msg.deinit(self._gpa);
        try ast.renderError(ast_err, msg.writer(self._gpa));

        // TODO: render `ast_err.extra.expected_tag`
        const byte_offset: Ast.ByteOffset = ast.tokens.items(.start)[ast_err.token];
        const loc = ast.tokenLocation(byte_offset, ast_err.token);
        const labels = .{Span{ .start = @intCast(loc.line_start), .end = @intCast(loc.line_end) }};
        _ = labels;

        return self.addErrorOwnedMessage(try msg.toOwnedSlice(self._gpa), null);
    }

    /// Record an error encountered during parsing or analysis.
    ///
    /// All parameters are borrowed. Errors own their data, so each parameter gets cloned onto the heap.
    fn addError(self: *Builder, message: string, labels: []Span, help: ?string) !void {
        const alloc = self._errors.allocator;
        const heap_message = try alloc.dupeZ(u8, message);
        const heap_labels = try alloc.dupe(Span, labels);
        const heap_help: ?string = if (help == null) null else try alloc.dupeZ(help.?);
        const err = try Error{ .message = heap_message, .labels = heap_labels, .help = heap_help };
        try self._errors.append(err);
    }

    /// Create and record an error. `message` is an owned slice moved into the new Error.
    // fn addErrorOwnedMessage(self: *Builder, message: string, labels: []Span, help: ?string) !void {
    fn addErrorOwnedMessage(self: *Builder, message: string, help: ?string) !void {
        // const heap_labels = try alloc.dupe(labels);
        const heap_help: ?string = if (help == null) null else try self._gpa.dupeZ(u8, help.?);
        const err = Error{ .message = message, .help = heap_help };
        // const err = try Error{ .message = message, .labels = heap_labels, .help = heap_help };
        try self._errors.append(self._gpa, err);
    }

    // pub const Result = struct {
    //     semantic: Semantic,
    //     errors: std.ArrayList(Error),

    //     pub fn deinit(self: *Result) void {
    //         self.semantic.deinit();
    //         self.deinitErrors();
    //     }

    //     pub fn hasErrors(self: *Result) bool {
    //         return self.errors.items.len != 0;
    //     }

    //     /// Free the error list, leaving `semantic` untouched.
    //     pub fn deinitErrors(self: *Result) void {
    //         const err_alloc = self.errors.allocator;
    //         var i: usize = 0;
    //         const len = self.errors.items.len;
    //         while (i < len) {
    //             self.errors.items[i].deinit(err_alloc);
    //             i += 1;
    //         }
    //         self.errors.deinit();
    //     }
    // };
    pub const Result = Error.Result(Semantic);
};

const IS_DEBUG = builtin.mode == .Debug;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Type = std.builtin.Type;

const assert = std.debug.assert;
const print = std.debug.print;

pub const Semantic = @import("./semantic/Semantic.zig");
const Scope = Semantic.Scope;
const Symbol = Semantic.Symbol;

const Ast = std.zig.Ast;
const Node = Ast.Node;
const NodeIndex = Ast.Node.Index;
// Struct used in AST tokens SOA is not pub so we hack it in here.
const RawToken = struct {
    tag: std.zig.Token.Tag,
    start: u32,
};
const TokenIndex = Ast.TokenIndex;

const Error = @import("./Error.zig");
const Span = @import("./source.zig").Span;

const str = @import("str.zig");
const string = str.string;
const stringSlice = str.stringSlice;
