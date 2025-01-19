pub const WalkState = enum { Continue, Skip, Stop };

/// Traverses an AST in a depth-first manner.
///
/// Visitors are structs (or some other container) that control the walk and
/// optionally inspect each node as it is encountered.
///
/// ## Visiting Nodes
/// For each kind of node (e.g. `fn_decl`), `Walker` will call `Visitor`'s
/// `visit_fn_decl` method with 1. a mutable pointer to a Visitor instance and
/// 2. the node id. Visitors do not need methods for each kind of node; missing
/// visit methods will simply not be called.
///
/// Visit methods control the walk by returning a `WalkState`. This has the
/// following behavior:
/// - `Continue`: keep traversing the AST as normal
/// - `Skip`: do not stop traversal, but do not visit this node's children
/// - `Stop`: halt traversal. This is effectively `return`.
///
/// ## Hooks
/// Visitors may optionally have an `enterNode` and/or `exitNode` method. These
/// get called before and after visiting each node, respectively. Just like
/// visit methods, these are also passed a mutable pointer to a Visitor instance
/// and the current node's id.
pub fn Walker(Visitor: type, Error: type) type {
    const tag_info = @typeInfo(Node.Tag).Enum;
    const VisitFn = fn (visitor: *Visitor, node: Node.Index) Error!WalkState;

    // stores pointers to Visitor's visit methods. Each kind of node (ie each
    // variant of Node.Tag) gets a similarly named visit function. For example,
    // when visiting a `fn_proto` node, a pointer to `visit_fn_proto` gets
    // stored in the vtable at the int index for `fn_proto`.
    comptime var vtable: [tag_info.fields.len]?*VisitFn = undefined;
    for (tag_info.fields) |field| {
        const id: usize = field.value;
        // e.g. visit_if_stmt, visit_less_than, visit_greater_than
        const visit_fn_name = "visit_" ++ field.name;

        // visitors who do not care about visiting certain kinds of nodes do not
        // need to implement visitor methods for them. Visiting will simply be
        // skipped, and walking will continue as normal.
        if (!@hasDecl(Visitor, visit_fn_name)) {
            vtable[id] = null;
            continue;
        }

        const visit_fn = @field(Visitor, visit_fn_name);
        if (@typeInfo(@TypeOf(visit_fn)) != .Fn) {
            @compileError("Visitor method '" + @typeName(Visitor) ++ "." ++ visit_fn_name ++ "' must be function.");
        }
        vtable[id] = &visit_fn;
    }

    return struct {
        ast: *const Ast,
        visitor: *Visitor,
        stack: std.ArrayListUnmanaged(StackEntry) = .{},
        alloc: Allocator,
        // visit_vtable: [tag_info.fields.len]?*VisitFn,

        const Self = @This();

        /// Initialize this walker's stack in preparation for a walk. It is
        /// recommended to use an arena for `allocator`.
        pub fn init(allocator: Allocator, ast: *const Ast, visitor: *Visitor) Allocator.Error!Self {
            var self = Self{ .alloc = allocator, .ast = ast, .visitor = visitor };
            // var stackfb = std.heap.stackFallback(64, allocator);
            // const stack = stackfb.get();
            const root_decls = ast.rootDecls();
            try self.stack.ensureTotalCapacity(
                allocator,
                // 2x b/c each root decl gets an enter & exit node
                @max(ast.nodes.len >> 4, 8 + (2 * root_decls.len)),
            );

            // // push root declarations onto stack in reverse order so that nodes
            // // are visited in a left-to-right depth first fashion
            // const root_decls_rev: []StackEntry = try stack.alloc(StackEntry, root_decls.len);
            // defer stack.free(root_decls_rev);
            for (0..root_decls.len) |i| {
                const node = root_decls[root_decls.len - i - 1];
                // entries are popped off end so exit nodes must be pushed first
                self.stack.appendAssumeCapacity(.{ .id = node, .kind = .exit });
                self.stack.appendAssumeCapacity(.{ .id = node, .kind = .enter });
            }

            return self;
        }

        inline fn enterNode(self: *Self, node: Node.Index) Error!void {
            if (@hasDecl(Visitor, "enterNode")) return self.visitor.enterNode(node);
        }

        inline fn exitNode(self: *Self, node: Node.Index) void {
            if (@hasDecl(Visitor, "exitNode")) return self.visitor.exitNode(node);
        }

        pub fn walk(self: *Self) Error!void {
            const tags: []const Node.Tag = self.ast.nodes.items(.tag);

            while (self.stack.popOrNull()) |entry| {
                if (entry.kind == .exit) {
                    self.exitNode(entry.id);
                    continue;
                }
                const node = entry.id;
                const tag = tags[node];

                try self.enterNode(node);

                const state = if (vtable[@intFromEnum(tag)]) |visit_fn|
                    try @call(.auto, visit_fn, .{ self.visitor, node })
                else
                    WalkState.Continue;

                switch (state) {
                    .Continue => try self.pushChildren(node, tag),
                    .Skip => {},
                    .Stop => return,
                }
            }
        }

        fn pushChildren(self: *Self, node: Node.Index, tag: Node.Tag) Allocator.Error!void {
            const datas: []const Node.Data = self.ast.nodes.items(.data);
            const data = datas[node];

            switch (NodeDataKind.from(tag)) {
                // lhs/rhs are nodes. either may be omitted
                .node => {
                    try self.push(data.rhs);
                    try self.push(data.lhs);
                },
                // lhs/rhs are definitely-present nodes
                .node_unconditional => {
                    try self.pushUnconditional(data.rhs);
                    try self.pushUnconditional(data.lhs);
                },
                // only lhs is a node; rhs is ignored
                .node_token, .node_unset => {
                    try self.push(data.lhs);
                },
                // only rhs is a node, lhs is ignored
                .token_node, .unset_node => {
                    try self.push(data.rhs);
                },
                .node_subrange => {
                    try self.push(data.lhs);
                    const range = self.ast.extraData(data.rhs, Node.SubRange);
                    assert(range.end - range.start > 0);
                    const members = self.ast.extra_data[range.start..range.end];
                    try self.pushN(members);
                },
                .subrange_node => {
                    try self.push(data.rhs);
                    const range = self.ast.extraData(data.lhs, Node.SubRange);
                    assert(range.end - range.start > 0);
                    const members = self.ast.extra_data[range.start..range.end];
                    try self.pushN(members);
                },
                .subrange => {
                    const members = self.ast.extra_data[data.lhs..data.rhs];
                    try self.pushN(members);
                },
                // lhs/rhs both ignored
                .unset, .token => {},
                else => @panic("todo"),
            }
        }

        inline fn push(self: *Self, node: Node.Index) Allocator.Error!void {
            @setRuntimeSafety(!util.IS_DEBUG);

            if (node == Semantic.NULL_NODE) return;
            util.assert(
                node < self.ast.nodes.len,
                "Received out-of-bounds node (id: {d}, nodes.len: {d})",
                .{ node, self.ast.nodes.len },
            );

            try self.stack.append(self.alloc, .{ .id = node, .kind = .exit });
            return self.stack.append(self.alloc, .{ .id = node, .kind = .enter });
        }
        /// Push this node, assuming it is non-null
        inline fn pushUnconditional(self: *Self, node: Node.Index) Allocator.Error!void {
            self.assertInRange(node);
            try self.stack.append(self.alloc, .{ .id = node, .kind = .exit });
            return self.stack.append(self.alloc, .{ .id = node, .kind = .enter });
        }

        inline fn pushN(self: *Self, nodes: []const Node.Index) Allocator.Error!void {
            try self.stack.ensureUnusedCapacity(self.alloc, 2 * nodes.len);
            var it = std.mem.reverseIterator(nodes);
            while (it.next()) |node| {
                self.assertInRange(node);
                self.stack.appendAssumeCapacity(.{ .id = node, .kind = .exit });
                self.stack.appendAssumeCapacity(.{ .id = node, .kind = .enter });
            }
        }
        inline fn assertInRange(self: *Self, node: Node.Index) void {
            const len = self.ast.nodes.len;

            util.assert(node != Semantic.NULL_NODE, "Tried to push null node onto stack", .{});
            {
                @setRuntimeSafety(!util.IS_DEBUG);
                util.assert(node < len, "Tried to push out-of-bounds node (id: {d}, nodes.len: {d}). It's likely a token or extra_data index.", .{ node, len });
            }
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit(self.alloc);
        }
    };
}

const StackEntry = struct {
    id: Node.Index,
    kind: Kind = .enter,
    pub const Kind = enum { enter, exit };
};

const NodeDataKind = enum {
    /// lhs and rhs are always unset
    unset,
    /// lhs and rhs are both node indexes. Either (or both) may be omitted
    node,
    /// lhs and rhs are both token indexes. Often used to get slice view into
    /// token list.
    token,
    /// lhs and rhs are indexes into `extra_data`. Used to make a slice.
    extra,
    /// lhs and rhs are both node indexes. they are never omitted or the null
    /// node.
    ///
    /// Treat this the same as `.node`. It's only used for optimizations.
    node_unconditional,
    subrange,

    /// lhs is node index, rhs is token index
    node_token,
    /// lhs is node index, rhs is always unset
    node_unset,
    /// lhs is node index, rhs is index into `extra_data`
    node_extra,
    /// lhs is node index, rhs is a subrange list at `extra_data[rhs]`
    node_subrange,

    /// lhs is token index, rhs is node index
    token_node,
    /// lhs is always unset, rhs is node index
    unset_node,
    /// lhs is index into extra_data, rhs is token index
    extra_node,
    /// lhs is a subrange list at `extra_data[lhs]`, rhs is node index
    subrange_node,

    /// lhs is token index, rhs is unset
    token_unset,
    /// lhs is unset, rhs is token index
    unset_token,

    fn from(tag: Node.Tag) NodeDataKind {
        const K = NodeDataKind;
        return switch (tag) {
            // sub_list[lhs...rhs]
            .root => K.subrange,
            // `usingnamespace lhs;`. rhs unused. main_token is `usingnamespace`.
            .@"usingnamespace" => K.node_unset,
            // lhs is test name token (must be string literal or identifier), if any.
            // rhs is the body node.
            .test_decl => K.token_node,
            // lhs is the index into extra_data.
            // rhs is the initialization expression, if any.
            // main_token is `var` or `const`.
            .global_var_decl => K.extra_node,
            // `var a: x align(y) = rhs`
            // lhs is the index into extra_data.
            // main_token is `var` or `const`.
            .local_var_decl => K.extra_node,
            // `var a: lhs = rhs`. lhs and rhs may be unused.
            // Can be local or global.
            // main_token is `var` or `const`.
            .simple_var_decl => K.node,
            // `var a align(lhs) = rhs`. lhs and rhs may be unused.
            // Can be local or global.
            // main_token is `var` or `const`.
            .aligned_var_decl => K.node,
            // lhs is the identifier token payload if any,
            // rhs is the deferred expression.
            .@"errdefer" => K.token_node,
            // lhs is unused.
            // rhs is the deferred expression.
            .@"defer" => K.unset_node,
            // lhs catch rhs
            // lhs catch |err| rhs
            // main_token is the `catch` keyword.
            // payload is determined by looking at the next token after the `catch` keyword.
            .@"catch" => K.node,
            // `lhs.a`. main_token is the dot. rhs is the identifier token index.
            .field_access => K.node_token,
            // `lhs.?`. main_token is the dot. rhs is the `?` token index.
            .unwrap_optional => K.node_token,
            // `lhs == rhs`. main_token is op.
            .equal_equal => K.node_unconditional,
            // `lhs != rhs`. main_token is op.
            .bang_equal => K.node_unconditional,
            // `lhs < rhs`. main_token is op.
            .less_than => K.node_unconditional,
            // `lhs > rhs`. main_token is op.
            .greater_than => K.node_unconditional,
            // `lhs <= rhs`. main_token is op.
            .less_or_equal => K.node_unconditional,
            // `lhs >= rhs`. main_token is op.
            .greater_or_equal => K.node_unconditional,
            // `lhs *= rhs`. main_token is op.
            .assign_mul => K.node_unconditional,
            // `lhs /= rhs`. main_token is op.
            .assign_div => K.node_unconditional,
            // `lhs %= rhs`. main_token is op.
            .assign_mod => K.node_unconditional,
            // `lhs += rhs`. main_token is op.
            .assign_add => K.node_unconditional,
            // `lhs -= rhs`. main_token is op.
            .assign_sub => K.node_unconditional,
            // `lhs <<= rhs`. main_token is op.
            .assign_shl => K.node_unconditional,
            // `lhs <<|= rhs`. main_token is op.
            .assign_shl_sat => K.node_unconditional,
            // `lhs >>= rhs`. main_token is op.
            .assign_shr => K.node_unconditional,
            // `lhs &= rhs`. main_token is op.
            .assign_bit_and => K.node_unconditional,
            // `lhs ^= rhs`. main_token is op.
            .assign_bit_xor => K.node_unconditional,
            // `lhs |= rhs`. main_token is op.
            .assign_bit_or => K.node_unconditional,
            // `lhs *%= rhs`. main_token is op.
            .assign_mul_wrap => K.node_unconditional,
            // `lhs +%= rhs`. main_token is op.
            .assign_add_wrap => K.node_unconditional,
            // `lhs -%= rhs`. main_token is op.
            .assign_sub_wrap => K.node_unconditional,
            // `lhs *|= rhs`. main_token is op.
            .assign_mul_sat => K.node_unconditional,
            // `lhs +|= rhs`. main_token is op.
            .assign_add_sat => K.node_unconditional,
            // `lhs -|= rhs`. main_token is op.
            .assign_sub_sat => K.node_unconditional,
            // `lhs = rhs`. main_token is op.
            .assign => K.node_unconditional,
            // `a, b, ... = rhs`. main_token is op. lhs is index into `extra_data`
            // of an lhs elem count followed by an array of that many `Node.Index`,
            // with each node having one of the following types:
            // * `global_var_decl`
            // * `local_var_decl`
            // * `simple_var_decl`
            // * `aligned_var_decl`
            // * Any expression node
            // The first 3 types correspond to a `var` or `const` lhs node (note
            // that their `rhs` is always 0). An expression node corresponds to a
            // standard assignment LHS (which must be evaluated as an lvalue).
            // There may be a preceding `comptime` token, which does not create a
            // corresponding `comptime` node so must be manually detected.
            .assign_destructure => K.extra_node,
            // `lhs || rhs`. main_token is the `||`.
            .merge_error_sets => K.node_unconditional,
            // `lhs * rhs`. main_token is the `*`.
            .mul => K.node_unconditional,
            // `lhs / rhs`. main_token is the `/`.
            .div => K.node_unconditional,
            // `lhs % rhs`. main_token is the `%`.
            .mod => K.node_unconditional,
            // `lhs ** rhs`. main_token is the `**`.
            .array_mult => K.node_unconditional,
            // `lhs *% rhs`. main_token is the `*%`.
            .mul_wrap => K.node_unconditional,
            // `lhs *| rhs`. main_token is the `*|`.
            .mul_sat => K.node_unconditional,
            // `lhs + rhs`. main_token is the `+`.
            .add => K.node_unconditional,
            // `lhs - rhs`. main_token is the `-`.
            .sub => K.node_unconditional,
            // `lhs ++ rhs`. main_token is the `++`.
            .array_cat => K.node_unconditional,
            // `lhs +% rhs`. main_token is the `+%`.
            .add_wrap => K.node_unconditional,
            // `lhs -% rhs`. main_token is the `-%`.
            .sub_wrap => K.node_unconditional,
            // `lhs +| rhs`. main_token is the `+|`.
            .add_sat => K.node_unconditional,
            // `lhs -| rhs`. main_token is the `-|`.
            .sub_sat => K.node_unconditional,
            // `lhs << rhs`. main_token is the `<<`.
            .shl => K.node_unconditional,
            // `lhs <<| rhs`. main_token is the `<<|`.
            .shl_sat => K.node_unconditional,
            // `lhs >> rhs`. main_token is the `>>`.
            .shr => K.node_unconditional,
            // `lhs & rhs`. main_token is the `&`.
            .bit_and => K.node_unconditional,
            // `lhs ^ rhs`. main_token is the `^`.
            .bit_xor => K.node_unconditional,
            // `lhs | rhs`. main_token is the `|`.
            .bit_or => K.node_unconditional,
            // `lhs orelse rhs`. main_token is the `orelse`.
            .@"orelse" => K.node_unconditional,
            // `lhs and rhs`. main_token is the `and`.
            .bool_and => K.node_unconditional,
            // `lhs or rhs`. main_token is the `or`.
            .bool_or => K.node_unconditional,
            // `op lhs`. rhs unused. main_token is op.
            .bool_not => K.node_unset,
            // `op lhs`. rhs unused. main_token is op.
            .negation => K.node_unset,
            // `op lhs`. rhs unused. main_token is op.
            .bit_not => K.node_unset,
            // `op lhs`. rhs unused. main_token is op.
            .negation_wrap => K.node_unset,
            // `op lhs`. rhs unused. main_token is op.
            .address_of => K.node_unset,
            // `op lhs`. rhs unused. main_token is op.
            .@"try" => K.node_unset,
            // `op lhs`. rhs unused. main_token is op.
            .@"await" => K.node_unset,
            // `?lhs`. rhs unused. main_token is the `?`.
            .optional_type => K.node_unset,
            // `[lhs]rhs`.
            .array_type => K.node,
            // `[lhs:a]b`. `ArrayTypeSentinel[rhs]`.
            .array_type_sentinel => K.node_extra,
            // `[*]align(lhs) rhs`. lhs can be omitted.
            // `*align(lhs) rhs`. lhs can be omitted.
            // `[]rhs`.
            // main_token is the asterisk if a pointer or the lbracket if a slice
            // main_token might be a ** token, which is shared with a parent/child
            // pointer type and may require special handling.
            .ptr_type_aligned => K.node,
            // `[*:lhs]rhs`. lhs can be omitted.
            // `*rhs`.
            // `[:lhs]rhs`.
            // main_token is the asterisk if a pointer or the lbracket if a slice
            // main_token might be a ** token, which is shared with a parent/child
            // pointer type and may require special handling.
            .ptr_type_sentinel => K.node,
            // lhs is index into ptr_type. rhs is the element type expression.
            // main_token is the asterisk if a pointer or the lbracket if a slice
            // main_token might be a ** token, which is shared with a parent/child
            // pointer type and may require special handling.
            .ptr_type => K.extra_node,
            // lhs is index into ptr_type_bit_range. rhs is the element type expression.
            // main_token is the asterisk if a pointer or the lbracket if a slice
            // main_token might be a ** token, which is shared with a parent/child
            // pointer type and may require special handling.
            .ptr_type_bit_range => K.extra_node,
            // `lhs[rhs..]`
            // main_token is the lbracket.
            .slice_open => K.node_unconditional,
            // `lhs[b..c]`. rhs is index into Slice
            // main_token is the lbracket.
            .slice => K.node_extra,
            // `lhs[b..c :d]`. rhs is index into SliceSentinel. Slice end "c" can be omitted.
            // main_token is the lbracket.
            .slice_sentinel => K.node_extra,
            // `lhs.*`. rhs is unused.
            .deref => K.node_unset,
            // `lhs[rhs]`.
            .array_access => K.node_unconditional,
            // `lhs{rhs}`. rhs can be omitted.
            .array_init_one => K.node,
            // `lhs{rhs,}`. rhs can *not* be omitted
            .array_init_one_comma => K.node_unconditional,
            // `.{lhs, rhs}`. lhs and rhs can be omitted.
            .array_init_dot_two => K.node,
            // Same as `array_init_dot_two` except there is known to be a trailing comma
            // before the final rbrace.
            .array_init_dot_two_comma => K.node,
            // `.{a, b}`. `sub_list[lhs..rhs]`.
            .array_init_dot => K.subrange,
            // Same as `array_init_dot` except there is known to be a trailing comma
            // before the final rbrace.
            .array_init_dot_comma => K.subrange,
            // `lhs{a, b}`. `sub_range_list[rhs]`. lhs can be omitted which means `.{a, b}`.
            .array_init => K.node_subrange,
            // Same as `array_init` except there is known to be a trailing comma
            // before the final rbrace.
            .array_init_comma => K.node_subrange,
            // `lhs{.a = rhs}`. rhs can be omitted making it empty.
            // main_token is the lbrace.
            .struct_init_one => K.node,
            // `lhs{.a = rhs,}`. rhs can *not* be omitted.
            // main_token is the lbrace.
            .struct_init_one_comma => K.node_unconditional,
            // `.{.a = lhs, .b = rhs}`. lhs and rhs can be omitted.
            // main_token is the lbrace.
            // No trailing comma before the rbrace.
            .struct_init_dot_two => K.node,
            // Same as `struct_init_dot_two` except there is known to be a trailing comma
            // before the final rbrace.
            .struct_init_dot_two_comma => K.node,
            // `.{.a = b, .c = d}`. `sub_list[lhs..rhs]`.
            // main_token is the lbrace.
            .struct_init_dot => K.subrange,
            // Same as `struct_init_dot` except there is known to be a trailing comma
            // before the final rbrace.
            .struct_init_dot_comma => K.subrange,
            // `lhs{.a = b, .c = d}`. `sub_range_list[rhs]`.
            // lhs can be omitted which means `.{.a = b, .c = d}`.
            // main_token is the lbrace.
            .struct_init => K.node_subrange,
            // Same as `struct_init` except there is known to be a trailing comma
            // before the final rbrace.
            .struct_init_comma => K.node_subrange,
            // `lhs(rhs)`. rhs can be omitted.
            // main_token is the lparen.
            .call_one => K.node,
            // `lhs(rhs,)`. rhs can be omitted.
            // main_token is the lparen.
            .call_one_comma => K.node,
            // `async lhs(rhs)`. rhs can be omitted.
            .async_call_one => K.node,
            // `async lhs(rhs,)`.
            .async_call_one_comma => K.node,
            // `lhs(a, b, c)`. `SubRange[rhs]`.
            // main_token is the `(`.
            .call => K.node_subrange,
            // `lhs(a, b, c,)`. `SubRange[rhs]`.
            // main_token is the `(`.
            .call_comma => K.node_subrange,
            // `async lhs(a, b, c)`. `SubRange[rhs]`.
            // main_token is the `(`.
            .async_call => K.node_subrange,
            // `async lhs(a, b, c,)`. `SubRange[rhs]`.
            // main_token is the `(`.
            .async_call_comma => K.node_subrange,
            // `switch(lhs) {}`. `SubRange[rhs]`.
            .@"switch" => K.node_subrange,
            // Same as switch except there is known to be a trailing comma
            // before the final rbrace
            .switch_comma => K.node_subrange,
            // `lhs => rhs`. If lhs is omitted it means `else`.
            // main_token is the `=>`
            .switch_case_one => K.node,
            // Same ast `switch_case_one` but the case is inline
            .switch_case_inline_one => K.node,
            // `a, b, c => rhs`. `SubRange[lhs]`.
            // main_token is the `=>`
            .switch_case => K.node_subrange,
            // Same ast `switch_case` but the case is inline
            .switch_case_inline => K.node_subrange,
            // `lhs...rhs`.
            .switch_range => K.node_unconditional,
            // `while (lhs) rhs`.
            // `while (lhs) |x| rhs`.
            .while_simple => K.node_unconditional,
            // `while (lhs) : (a) b`. `WhileCont[rhs]`.
            // `while (lhs) : (a) b`. `WhileCont[rhs]`.
            .while_cont => K.node_extra,
            // `while (lhs) : (a) b else c`. `While[rhs]`.
            // `while (lhs) |x| : (a) b else c`. `While[rhs]`.
            // `while (lhs) |x| : (a) b else |y| c`. `While[rhs]`.
            // The cont expression part `: (a)` may be omitted.
            .@"while" => K.node_extra,
            // `for (lhs) rhs`.
            .for_simple => K.node,
            // `for (lhs[0..inputs]) lhs[inputs + 1] else lhs[inputs + 2]`. `For[rhs]`.
            .@"for" => K.node_extra,
            // `lhs..rhs`. rhs can be omitted.
            .for_range => K.node,
            // `if (lhs) rhs`.
            // `if (lhs) |a| rhs`.
            .if_simple => K.node_unconditional,
            // `if (lhs) a else b`. `If[rhs]`.
            // `if (lhs) |x| a else b`. `If[rhs]`.
            // `if (lhs) |x| a else |y| b`. `If[rhs]`.
            .@"if" => K.node_extra,
            // `suspend lhs`. lhs can be omitted. rhs is unused.
            .@"suspend" => K.node_unset,
            // `resume lhs`. rhs is unused.
            .@"resume" => K.node_unset,
            // `continue`. lhs is token index of label if any. rhs is unused.
            .@"continue" => K.token_unset,
            // `break :lhs rhs`
            // both lhs and rhs may be omitted.
            .@"break" => K.node,
            // `return lhs`. lhs can be omitted. rhs is unused.
            .@"return" => K.node_unset,
            // `fn (a: lhs) rhs`. lhs can be omitted.
            // anytype and ... parameters are omitted from the AST tree.
            // main_token is the `fn` keyword.
            // extern function declarations use this tag.
            .fn_proto_simple => K.node,
            // `fn (a: b, c: d) rhs`. `sub_range_list[lhs]`.
            // anytype and ... parameters are omitted from the AST tree.
            // main_token is the `fn` keyword.
            // extern function declarations use this tag.
            .fn_proto_multi => K.node_subrange,
            // `fn (a: b) addrspace(e) linksection(f) callconv(g) rhs`. `FnProtoOne[lhs]`.
            // zero or one parameters.
            // anytype and ... parameters are omitted from the AST tree.
            // main_token is the `fn` keyword.
            // extern function declarations use this tag.
            .fn_proto_one => K.extra_node,
            // `fn (a: b, c: d) addrspace(e) linksection(f) callconv(g) rhs`. `FnProto[lhs]`.
            // anytype and ... parameters are omitted from the AST tree.
            // main_token is the `fn` keyword.
            // extern function declarations use this tag.
            .fn_proto => K.extra_node,
            // lhs is the fn_proto.
            // rhs is the function body block.
            // Note that extern function declarations use the fn_proto tags rather
            // than this one.
            .fn_decl => K.node, // unconditional?
            // `anyframe->rhs`. main_token is `anyframe`. `lhs` is arrow token index.
            .anyframe_type => K.token_node,
            // Both lhs and rhs unused.
            .anyframe_literal => K.unset,
            // Both lhs and rhs unused.
            .char_literal => K.unset,
            // Both lhs and rhs unused.
            .number_literal => K.unset,
            // Both lhs and rhs unused.
            .unreachable_literal => K.unset,
            // Both lhs and rhs unused.
            // Most identifiers will not have explicit AST nodes, however for expressions
            // which could be one of many different kinds of AST nodes, there will be an
            // identifier AST node for it.
            .identifier => K.unset,
            // lhs is the dot token index, rhs unused, main_token is the identifier.
            .enum_literal => K.token_unset,
            // main_token is the string literal token
            // Both lhs and rhs unused.
            .string_literal => K.unset,
            // main_token is the first token index (redundant with lhs)
            // lhs is the first token index; rhs is the last token index.
            // Could be a series of multiline_string_literal_line tokens, or a single
            // string_literal token.
            .multiline_string_literal => K.token,
            // `(lhs)`. main_token is the `(`; rhs is the token index of the `)`.
            .grouped_expression => K.node_token,
            // `@a(lhs, rhs)`. lhs and rhs may be omitted.
            // main_token is the builtin token.
            .builtin_call_two => K.node,
            // Same as builtin_call_two but there is known to be a trailing comma before the rparen.
            .builtin_call_two_comma => K.node,
            // `@a(b, c)`. `sub_list[lhs..rhs]`.
            // main_token is the builtin token.
            .builtin_call => K.subrange,
            // Same as builtin_call but there is known to be a trailing comma before the rparen.
            .builtin_call_comma => K.subrange,
            // `error{a, b}`.
            // rhs is the rbrace, lhs is unused.
            .error_set_decl => K.unset_token,
            // `struct {}`, `union {}`, `opaque {}`, `enum {}`. `extra_data[lhs..rhs]`.
            // main_token is `struct`, `union`, `opaque`, `enum` keyword.
            .container_decl => K.extra,
            // Same as ContainerDecl but there is known to be a trailing comma
            // or semicolon before the rbrace.
            .container_decl_trailing => K.extra,
            // `struct {lhs, rhs}`, `union {lhs, rhs}`, `opaque {lhs, rhs}`, `enum {lhs, rhs}`.
            // lhs or rhs can be omitted.
            // main_token is `struct`, `union`, `opaque`, `enum` keyword.
            .container_decl_two => K.node,
            // Same as ContainerDeclTwo except there is known to be a trailing comma
            // or semicolon before the rbrace.
            .container_decl_two_trailing => K.node,
            // `struct(lhs)` / `union(lhs)` / `enum(lhs)`. `SubRange[rhs]`.
            .container_decl_arg => K.node_subrange,
            // Same as container_decl_arg but there is known to be a trailing
            // comma or semicolon before the rbrace.
            .container_decl_arg_trailing => K.node_subrange,
            // `union(enum) {}`. `sub_list[lhs..rhs]`.
            // Note that tagged unions with explicitly provided enums are represented
            // by `container_decl_arg`.
            .tagged_union => K.subrange,
            // Same as tagged_union but there is known to be a trailing comma
            // or semicolon before the rbrace.
            .tagged_union_trailing => K.subrange,
            // `union(enum) {lhs, rhs}`. lhs or rhs may be omitted.
            // Note that tagged unions with explicitly provided enums are represented
            // by `container_decl_arg`.
            .tagged_union_two => K.node,
            // Same as tagged_union_two but there is known to be a trailing comma
            // or semicolon before the rbrace.
            .tagged_union_two_trailing => K.node,
            // `union(enum(lhs)) {}`. `SubRange[rhs]`.
            .tagged_union_enum_tag => K.node_subrange,
            // Same as tagged_union_enum_tag but there is known to be a trailing comma
            // or semicolon before the rbrace.
            .tagged_union_enum_tag_trailing => K.node_subrange,
            // `a: lhs = rhs,`. lhs and rhs can be omitted.
            // main_token is the field name identifier.
            // lastToken() does not include the possible trailing comma.
            .container_field_init => K.node,
            // `a: lhs align(rhs),`. rhs can be omitted.
            // main_token is the field name identifier.
            // lastToken() does not include the possible trailing comma.
            .container_field_align => K.node,
            // `a: lhs align(c) = d,`. `container_field_list[rhs]`.
            // main_token is the field name identifier.
            // lastToken() does not include the possible trailing comma.
            .container_field => K.node_extra,
            // `comptime lhs`. rhs unused.
            .@"comptime" => K.node_unset,
            // `nosuspend lhs`. rhs unused.
            .@"nosuspend" => K.node_unset,
            // `{lhs rhs}`. rhs or lhs can be omitted.
            // main_token points at the lbrace.
            .block_two => K.node,
            // Same as block_two but there is known to be a semicolon before the rbrace.
            .block_two_semicolon => K.node,
            // `{}`. `sub_list[lhs..rhs]`.
            // main_token points at the lbrace.
            .block => K.subrange,
            // Same as block but there is known to be a semicolon before the rbrace.
            .block_semicolon => K.subrange,
            // `asm(lhs)`. rhs is the token index of the rparen.
            .asm_simple => K.node_token,
            // `asm(lhs, a)`. `Asm[rhs]`.
            .@"asm" => K.node_extra,
            // `[a] "b" (c)`. lhs is 0, rhs is token index of the rparen.
            // `[a] "b" (-> lhs)`. rhs is token index of the rparen.
            // main_token is `a`.
            .asm_output => K.node_token,
            // `[a] "b" (lhs)`. rhs is token index of the rparen.
            // main_token is `a`.
            .asm_input => K.node_token,
            // `error.a`. lhs is token index of `.`. rhs is token index of `a`.
            .error_value => K.token,
            // `lhs!rhs`. main_token is the `!`.
            .error_union => K.node, // unconditional?
        };
    }
};

const std = @import("std");
const util = @import("util");
const semantic = @import("../semantic.zig");
const mem = std.mem;
const assert = std.debug.assert;

const Allocator = mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;
// const NodeIndex = Ast.Node.Index;
const Semantic = semantic.Semantic;

const t = std.testing;
test Walker {
    const src =
        \\const std = @import("std");
        \\fn foo() void {
        \\  const x = 1;
        \\  std.debug.print("{d}\n", .{x});
        \\}
    ;

    const Foo = struct {
        depth: u32 = 0,
        nodes_visited: u32 = 0,
        const Self = @This();
        fn enterNode(self: *Self, _: Node.Index) !void {
            self.depth += 1;
            self.nodes_visited += 1;
        }
        fn exitNode(self: *Self, _: Node.Index) void {
            t.expect(self.depth > 0) catch @panic("expect failed");
            self.depth -= 1;
        }
    };
    const FooWalker = Walker(Foo, anyerror);

    var ast = try std.zig.Ast.parse(t.allocator, src, .zig);
    defer ast.deinit(t.allocator);
    var foo = Foo{};
    var walker = try FooWalker.init(t.allocator, &ast, &foo);
    defer walker.deinit();

    try walker.walk();
    try t.expectEqual(0, foo.depth);
    try t.expectEqual(16, foo.nodes_visited);
}
