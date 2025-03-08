// Copyright (c) 2025 Don Isaac
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//! AST walking and visiting utilities.

pub const WalkState = enum {
    /// Keep walking as normal
    Continue,
    /// Keep walking, but do not walk this node's children.
    Skip,
    /// Stop the walk. `walker.walk()` will return.
    Stop,
};

/// Traverses an [AST](#std.zig.Ast) in a depth-first manner.
///
/// Visitors are structs (or some other container) that control the walk and
/// optionally inspect each node as it is encountered.
///
/// ## Visiting Nodes
/// For each kind of node (e.g. `fn_decl`), `Walker` will call `Visitor`'s
/// `visit_fn_decl` method with a mutable pointer to a `Visitor` instance and
/// the node's id. Visitors do not need methods for each kind of node; missing
/// visit methods will simply not be called.
///
/// For example:
/// ```zig
/// pub fn visit_fn_decl(this: *Visitor, node: Node.Index) Error!WalkState;
/// ```
///
/// Some nodes have a "full" representation in the AST, as defined by
/// [Ast.full].  Like tag visitors, full node visitors are called with a mutable
/// pointer to the visitor and the node id. However, they also receive a pointer
/// to the full node. T They are named `visitFullNodeName`. In general, if there
/// is a `full.NodeName` struct in [Ast.full], there will be a corresponding
/// `visitNodeName` method in the visitor.
///
/// For example:
/// ```zig
/// pub fn visitFnProto(this: *Visitor, node: Node.Index, fn_proto: *const Ast.full.FnProto) Error!WalkState;
/// ```
///
/// A couple of important notes and caveats:
/// - Full node visitors are called _instead_ of tag visitors. If you have a `visitFnProto` method,
///   `visit_fn_proto` will not be called.
/// - Zig's parser does not create a unique node for function parameters. However,
///   they are still visited with `visitFnParam`. This does not apply to`
///   arguments passed to function call expressions.
///
/// ## Controlling the Walk
///
/// Visit methods control the walk by returning a `WalkState`. This has the
/// following behavior:
/// - `Continue`: keep traversing the AST as normal
/// - `Skip`: do not stop traversal, but do not visit this node's children
/// - `Stop`: halt traversal. This is effectively `return`.
///
///
/// ## Hooks
/// Visitors may optionally have an `enterNode` and/or `exitNode` method. These
/// get called before and after visiting each node, respectively. Just like
/// visit methods, these are also passed a mutable pointer to a Visitor instance
/// and the current node's id.
pub fn Walker(Visitor: type, Error: type) type {
    const tag_info = @typeInfo(Node.Tag).@"enum";

    const VisitFn = fn (visitor: *Visitor, node: Node.Index) Error!WalkState;
    const VisitFull = struct {
        fn VisitFull(Full: type) type {
            return fn (visitor: *Visitor, node: Node.Index, var_decl: *const Full) Error!WalkState;
        }
    }.VisitFull;
    // const VisitFullVarDeclFn = fn (visitor: *Visitor, node: Node.Index, var_decl: Ast.full.VarDecl) Error!WalkState;
    // const VisitFullFnProto

    const WalkerVTable = struct {
        // SAFETY: set immediately when iterating over tag infos. Only one
        // vtable is ever instantiated.
        tag_table: [tag_info.fields.len]?*const VisitFn = undefined,

        // "full node" visitors
        visitVarDecl: ?*const VisitFull(full.VarDecl) = null,
        visitAssignDestructure: ?*const VisitFull(full.AssignDestructure) = null,
        visitIf: ?*const VisitFull(full.If) = null,
        visitWhile: ?*const VisitFull(full.While) = null,
        visitFor: ?*const VisitFull(full.For) = null,
        visitFnProto: ?*const VisitFull(full.FnProto) = null,
        visitFnParam: ?*const VisitFull(full.FnProto.Param) = null,
        visitContainerField: ?*const VisitFull(full.ContainerField) = null,
        visitStructInit: ?*const VisitFull(full.StructInit) = null,
        visitArrayInit: ?*const VisitFull(full.ArrayInit) = null,
        visitArrayType: ?*const VisitFull(full.ArrayType) = null,
        visitPtrType: ?*const VisitFull(full.PtrType) = null,
        visitSlice: ?*const VisitFull(full.Slice) = null,
        visitContainerDecl: ?*const VisitFull(full.ContainerDecl) = null,
        visitSwitchCase: ?*const VisitFull(full.SwitchCase) = null,
        visitAsm: ?*const VisitFull(full.Asm) = null,
        visitCall: ?*const VisitFull(full.Call) = null,
    };

    // stores pointers to Visitor's visit methods. Each kind of node (ie each
    // variant of Node.Tag) gets a similarly named visit function. For example,
    // when visiting a `fn_proto` node, a pointer to `visit_fn_proto` gets
    // stored in the vtable at the int index for `fn_proto`.
    comptime var vtable: WalkerVTable = .{};

    // comptime var vtable: [tag_info.fields.len]?*const VisitFn = undefined;
    comptime var has_any_methods = false;
    for (tag_info.fields) |field| {
        const id: usize = field.value;
        // e.g. visit_if_stmt, visit_less_than, visit_greater_than
        const visit_fn_name = "visit_" ++ field.name;

        // visitors who do not care about visiting certain kinds of nodes do not
        // need to implement visitor methods for them. Visiting will simply be
        // skipped, and walking will continue as normal.
        if (!@hasDecl(Visitor, visit_fn_name)) {
            vtable.tag_table[id] = null;
            continue;
        }
        has_any_methods = true;
        const visit_fn = @field(Visitor, visit_fn_name);
        if (@typeInfo(@TypeOf(visit_fn)) != .@"fn") {
            @compileError("Visitor method '" + @typeName(Visitor) ++ "." ++ visit_fn_name ++ "' must be function.");
        }
        vtable.tag_table[id] = &visit_fn;
    }

    // "full node" visitors
    inline for (@typeInfo(WalkerVTable).@"struct".fields) |field| {
        const name = field.name;
        if (!std.mem.eql(u8, name, "tag_table")) {
            if (@hasDecl(Visitor, name)) {
                @field(vtable, name) = @field(Visitor, name);
            }
            has_any_methods = true;
        }
    }

    // It would be confusing for _nothing_ to happen after a walk b/c you misspelled visit_container_field or something
    if (!has_any_methods and
        !@hasDecl(Visitor, "enterNode") and
        !@hasDecl(Visitor, "exitNode"))
    {
        @compileError("Visitor '" ++ @typeName(Visitor) ++ "' has no visit methods. Did you forget to make them `pub`?");
    }

    return struct {
        /// AST being walked.
        ast: *const Ast,
        // store these to avoid repeated pointer arithmetic. Borrowed from `ast`.
        // len isn't needed b/c we can get it from there, and lets us save 1 word
        // per ptr.
        tags: [*]const Node.Tag,
        datas: [*]const Node.Data,

        visitor: *Visitor,
        stack: std.ArrayListUnmanaged(StackEntry) = .{},
        alloc: Allocator,

        const Self = @This();
        const WalkError = Error || Allocator.Error;

        /// Initialize this walker's stack in preparation for a walk. It is
        /// recommended to use an arena for `allocator`.
        pub fn init(allocator: Allocator, ast: *const Ast, visitor: *Visitor) Allocator.Error!Self {
            var self = Self{
                .ast = ast,
                .tags = ast.nodes.items(.tag).ptr,
                .datas = ast.nodes.items(.data).ptr,
                .alloc = allocator,
                .visitor = visitor,
            };
            // var stackfb = std.heap.stackFallback(64, allocator);
            // const stack = stackfb.get();
            const root_decls = ast.rootDecls();
            try self.stack.ensureTotalCapacity(
                allocator,
                // 2x b/c each root decl gets an enter & exit node
                @max(ast.nodes.len >> 4, 8 + (2 * root_decls.len)),
            );

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

        /// Walk over an `std.zig.Ast` with the provided `Visitor`.
        pub fn walk(self: *Self) WalkError!void {
            // Used by some full AST node getters. The meaning of this node depends on each getter.
            // Since this is re-used, care must be taken to avoid storing a reference to (now-clobbered) data.
            //
            // The most at-risk case is visitors storing references to full nodes
            // after specialized visitor methods return.
            //
            // W.R.T walking:
            // - walk()'s main body only ever dispatches tag-visitor calls, which never use this buffer
            // - walkFull() enqueues full nodes into the stack before returning. This copies
            //   whatever's in this buffer, so it can't be clobbered.
            //
            var buf: [1]Node.Index = undefined;
            var buf2: [2]Node.Index = undefined;

            var i = if (comptime util.IS_DEBUG) @as(u32, 0);

            while (self.stack.pop()) |entry| {
                if (comptime util.IS_DEBUG) i += 1;
                if (entry.kind == .exit) {
                    print("[{}] exit: {s} ({})\n", .{ self.stack.items.len, @tagName(self.tags[entry.id]), entry.id });
                    self.exitNode(entry.id);
                    continue;
                }
                const node = entry.id;
                const tag = self.tags[node];
                print("[{}] enter: {s} ({})\n", .{ self.stack.items.len, @tagName(tag), entry.id });
                print("{s}\n", .{self.ast.getNodeSource(entry.id)});

                try self.enterNode(node);

                // micro-optimization: avoid using`ast.fullFooNode` to 1) remove
                // redundant switch and 2) avoid passing &buffer when possible
                const should_stop: bool = try switch (tag) {
                    .global_var_decl,
                    .local_var_decl,
                    .simple_var_decl,
                    .aligned_var_decl,
                    => self.walkFull(full.VarDecl, node, tag, .visitVarDecl, .fullVarDecl, .{}),
                    // TODO: ensure `tag` is considered comptime-known

                    // ast.assignDestructure
                    .assign_destructure => self.walkFull(full.AssignDestructure, node, tag, .visitAssignDestructure, .assignDestructure, .{}),

                    .if_simple, .@"if" => self.walkFull(full.If, node, tag, .visitIf, .fullIf, .{}),
                    .while_simple, .while_cont, .@"while" => self.walkFull(full.While, node, tag, .visitWhile, .fullWhile, .{}),
                    .for_simple, .@"for" => self.walkFull(full.For, node, tag, .visitFor, .fullFor, .{}),

                    // ast.fullContainerField
                    .container_field_init => self.walkFull(full.ContainerField, node, tag, .visitContainerField, .containerFieldInit, .{}),
                    .container_field_align => self.walkFull(full.ContainerField, node, tag, .visitContainerField, .containerFieldAlign, .{}),
                    .container_field => self.walkFull(full.ContainerField, node, tag, .visitContainerField, .containerField, .{}),

                    // ast.fullFnProto
                    .fn_proto => self.walkFull(full.FnProto, node, tag, .visitFnProto, .fnProto, .{}),
                    .fn_proto_multi => self.walkFull(full.FnProto, node, tag, .visitFnProto, .fnProtoMulti, .{}),
                    .fn_proto_one => self.walkFull(full.FnProto, node, tag, .visitFnProto, .fnProtoOne, .{&buf}),
                    .fn_proto_simple => self.walkFull(full.FnProto, node, tag, .visitFnProto, .fnProtoSimple, .{&buf}),
                    // NOTE: .fn_decl is intentionally omitted. its lhs is `.fn_proto` and rhs is `.block*`,
                    // which get visited as expected via tag visitors + pushChildren

                    // ast.fullStructInit
                    .struct_init_one, .struct_init_one_comma => self.walkFull(full.StructInit, node, tag, .visitStructInit, .structInitOne, .{&buf}),
                    .struct_init_dot_two, .struct_init_dot_two_comma => self.walkFull(full.StructInit, node, tag, .visitStructInit, .structInitDotTwo, .{&buf2}),
                    .struct_init_dot, .struct_init_dot_comma => self.walkFull(full.StructInit, node, tag, .visitStructInit, .structInitDot, .{}),
                    .struct_init, .struct_init_comma => self.walkFull(full.StructInit, node, tag, .visitStructInit, .structInit, .{}),

                    // ast.fullArrayInit
                    .array_init_one, .array_init_one_comma => self.walkFull(full.ArrayInit, node, tag, .visitArrayInit, .arrayInitOne, .{&buf}),
                    .array_init_dot_two, .array_init_dot_two_comma => self.walkFull(full.ArrayInit, node, tag, .visitArrayInit, .arrayInitDotTwo, .{&buf2}),
                    .array_init_dot, .array_init_dot_comma => self.walkFull(full.ArrayInit, node, tag, .visitArrayInit, .arrayInitDot, .{}),
                    .array_init, .array_init_comma => self.walkFull(full.ArrayInit, node, tag, .visitArrayInit, .arrayInit, .{}),

                    // ast.fullArrayType
                    .array_type => self.walkFull(full.ArrayType, node, tag, .visitArrayType, .arrayType, .{}),
                    .array_type_sentinel => self.walkFull(full.ArrayType, node, tag, .visitArrayType, .arrayTypeSentinel, .{}),

                    // ast.fullPtrType
                    .ptr_type_aligned => self.walkFull(full.PtrType, node, tag, .visitPtrType, .ptrTypeAligned, .{}),
                    .ptr_type_sentinel => self.walkFull(full.PtrType, node, tag, .visitPtrType, .ptrTypeSentinel, .{}),
                    .ptr_type => self.walkFull(full.PtrType, node, tag, .visitPtrType, .ptrType, .{}),
                    .ptr_type_bit_range => self.walkFull(full.PtrType, node, tag, .visitPtrType, .ptrTypeBitRange, .{}),

                    // ast.fullSlice
                    .slice_open, .slice, .slice_sentinel => self.walkFull(full.Slice, node, tag, .visitSlice, .fullSlice, .{}),

                    // ast.fullContainerDecl
                    .root => unreachable,
                    .container_decl,
                    .container_decl_trailing,
                    .container_decl_arg,
                    .container_decl_arg_trailing,
                    .container_decl_two,
                    .container_decl_two_trailing,
                    .tagged_union,
                    .tagged_union_trailing,
                    .tagged_union_enum_tag,
                    .tagged_union_enum_tag_trailing,
                    .tagged_union_two,
                    .tagged_union_two_trailing,
                    => self.walkFull(full.ContainerDecl, node, tag, .visitContainerDecl, .fullContainerDecl, .{&buf2}),

                    // ast.fullSwitchCase
                    .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => self.walkFull(full.SwitchCase, node, tag, .visitSwitchCase, .fullSwitchCase, .{}),

                    // ast.fullAsm
                    .asm_simple, .@"asm" => self.walkFull(full.Asm, node, tag, .visitAsm, .fullAsm, .{}),

                    // ast.fullCall
                    .call, .call_comma, .async_call, .async_call_comma => self.walkFull(full.Call, node, tag, .visitCall, .callFull, .{}),
                    .call_one, .call_one_comma, .async_call_one, .async_call_one_comma => self.walkFull(full.Call, node, tag, .visitCall, .callOne, .{&buf}),

                    else => tag_visit: {
                        const state: WalkState = if (vtable.tag_table[@intFromEnum(tag)]) |visit_fn|
                            try @call(.auto, visit_fn, .{ self.visitor, node })
                        else
                            WalkState.Continue;

                        switch (state) {
                            .Continue => {
                                try self.pushChildren(node, tag);
                                break :tag_visit false;
                            },
                            .Skip => break :tag_visit false,
                            .Stop => break :tag_visit true,
                        }
                    },
                };
                if (should_stop) return;
            }
        }

        /// Walk a "full" AST node, visiting it with one of the specialized visitors
        /// in the vtable. Employs uncomfortable amounts of comptime fuckery.
        ///
        /// Returns `true` when visitors stop the walk (`WalkState.Stop`).
        fn walkFull(
            self: *Self,
            /// Full AST struct definition from `Ast.full`. Assumed to have a
            /// `Components` member type.
            Full: type,
            node: Node.Index,
            tag: Node.Tag,
            /// name of specialized visitor fn in vtable (as a `.tag`)
            /// example: `.fnProto`
            comptime vtable_fn_name: anytype,
            /// Name of AST method (as a `.tag`) used to get the full node
            /// example: `.fullFnProto`
            comptime fullGetterName: anytype,
            /// Arguments to pass to `fullGetter`. AST pointer and node id will
            /// be prepended/appended (respectively). For example:
            /// `ast.fullFnProto(&buf, node)` -> `.{&buf}`
            args: anytype,
        ) WalkError!bool {
            // early checks for better error messages
            comptime {
                if (!@hasField(WalkerVTable, @tagName(vtable_fn_name)))
                    @compileError(@tagName(vtable_fn_name) ++ " is not a specialized visitor fn name.");

                if (!@hasDecl(Ast, @tagName(fullGetterName)))
                    @compileError("std.zig.Ast has no method named '" ++ @tagName(fullGetterName) ++ "'.");
            }

            const visit_full_fn: ?*const VisitFull(Full) = @field(vtable, @tagName(vtable_fn_name));

            // e.g.: const fn_proto = self.ast.fullFnProto(&buf, node)
            const full_args = .{self.ast.*} ++ args ++ .{node};
            const fullGetter = @field(Ast, @tagName(fullGetterName));
            // handle heterogenous return signatures
            const info = @typeInfo(@TypeOf(fullGetter));
            const full_node: Full = if (comptime @typeInfo(info.@"fn".return_type.?) == .optional)
                @call(.auto, fullGetter, full_args) orelse unreachable
            else
                @call(.auto, fullGetter, full_args);

            // Call the full visitor if one exists. Fall back to tag visitors.
            // Either way, the full node is still traversed correctly.
            const state: WalkState = if (visit_full_fn) |visitFullFn|
                try visitFullFn(self.visitor, node, &full_node)
            else if (vtable.tag_table[@intFromEnum(tag)]) |visitTagFn|
                try visitTagFn(self.visitor, node)
            else
                WalkState.Continue;

            switch (state) {
                .Continue => try self.pushFullNode(Full.Components, node, full_node.ast),
                .Skip => return false,
                .Stop => return true,
            }

            // fn params don't have their own node. We need to hack in a visit()
            // for them. Even though params is typed as []const Node.Index, it
            // really isn't. Attempts to visit them as-is often leads to infinite
            // recursion.
            if (comptime Full == full.FnProto) {
                const Item = Node.Index;
                var temp = std.heap.stackFallback(8 * @sizeOf(Item), self.alloc);
                var parambuf = std.ArrayList(Item).init(temp.get());
                defer parambuf.deinit();
                try parambuf.ensureTotalCapacityPrecise(8);

                var it: full.FnProto.Iterator = full_node.iterate(self.ast);
                while (it.next()) |param| {
                    if (comptime vtable.visitFnParam) |visitFnParam| {
                        switch (try visitFnParam(self.visitor, node, param)) {
                            .Continue => {},
                            .Skip => continue,
                            .Stop => return true,
                        }
                    }
                    if (param.type_expr != Semantic.NULL_NODE) try parambuf.append(param.type_expr);
                }
                std.mem.reverse(Item, parambuf.items);
                try self.pushManyUnconditional(parambuf.items);
            }
            return false;
        }

        /// Use comptime fuckery to push a `FullNode.Components` subtree onto
        /// the stack in reverse order.
        fn pushFullNode(self: *Self, Components: type, own_id: Node.Index, components: Components) Allocator.Error!void {
            const info = @typeInfo(Components);
            const fields = info.@"struct".fields;
            // @compileLog(fields);
            try self.stack.ensureUnusedCapacity(self.alloc, 2 * fields.len);

            // NOTE: std.mem.reverseIterator does not work in comptime
            inline for (0..fields.len) |i| {
                const idx = fields.len - i - 1;
                const field = fields[idx];
                const is_token = comptime mem.endsWith(u8, field.name, "_token") or
                    token_names.has(field.name);

                const is_specific_undesirable_node = comptime Components == full.FnProto.Components and
                    (std.mem.eql(u8, field.name, "proto_node") or
                        std.mem.eql(u8, field.name, "params"));

                if (!is_token and !is_specific_undesirable_node) {
                    const subnode: field.type = @field(components, field.name);
                    switch (@TypeOf(subnode)) {
                        []const Node.Index, []Node.Index => {
                            try self.ensureStackCapacity(subnode.len);
                            for (0..subnode.len) |j| {
                                const el: Node.Index = subnode[subnode.len - j - 1];
                                util.assert(el != own_id, "Cycle detected on node {d}", .{own_id});
                                self.push(el, .{ .assume_capacity = true });
                            }
                        },
                        u32 => if (subnode != Semantic.NULL_NODE) {
                            if (comptime std.mem.eql(u8, field.name, "proto_node")) {
                                if (own_id != subnode) try self.push(subnode, .{ .maybe_null = false });
                            } else {
                                util.assert(subnode != own_id, "Cycle detected on node {d}", .{own_id});
                                try self.push(subnode, .{ .maybe_null = false });
                            }
                        },
                        bool => {},
                        else => |Unsupported| {
                            @compileError(@typeName(Components) ++ "." ++ field.name ++ " has unsupported type " ++ @typeName(Unsupported) ++ ".");
                        },
                    }
                }
            }
        }

        const token_names = std.StaticStringMap(void).initComptime(.{
            .{"lparen"},
            .{"rparen"},
            .{"lbrace"},
            .{"rbrace"},
            .{"lbracket"},
            .{"rbracket"},
        });

        fn pushChildren(self: *Self, node: Node.Index, tag: Node.Tag) Allocator.Error!void {
            const data = self.datas[node];

            switch (NodeDataKind.from(tag)) {
                // lhs/rhs are nodes. either may be omitted
                .node => {
                    try self.ensureStackCapacity(2);
                    self.push(data.rhs, .{ .assume_capacity = true });
                    self.push(data.lhs, .{ .assume_capacity = true });
                },
                // lhs/rhs are definitely-present nodes
                .node_unconditional => {
                    try self.ensureStackCapacity(2);
                    self.push(data.rhs, .{ .assume_capacity = true });
                    self.push(data.lhs, .{ .assume_capacity = true });
                },
                // only lhs is a node; rhs is ignored
                .node_token, .node_unset => {
                    try self.push(data.lhs, .{});
                },
                // only rhs is a node, lhs is ignored
                .token_node, .unset_node => {
                    try self.push(data.rhs, .{});
                },
                .node_subrange => {
                    try self.push(data.lhs, .{});
                    const range = self.ast.extraData(data.rhs, Node.SubRange);
                    assert(range.end - range.start > 0);
                    const members = self.ast.extra_data[range.start..range.end];
                    try self.pushManyUnconditional(members);
                },
                .subrange_node => {
                    try self.push(data.rhs, .{});
                    const range = self.ast.extraData(data.lhs, Node.SubRange);
                    assert(range.end - range.start > 0);
                    const members = self.ast.extra_data[range.start..range.end];
                    try self.pushManyUnconditional(members);
                },
                .subrange => {
                    const members = self.ast.extra_data[data.lhs..data.rhs];
                    try self.pushManyUnconditional(members);
                },
                // lhs/rhs both ignored
                .unset, .token, .token_unset, .unset_token => {},
                else => |kind| if (comptime util.IS_DEBUG) std.debug.panic(
                    "todo: {s} ({s})",
                    .{ @tagName(kind), @tagName(tag) },
                ),
            }
        }

        const PushOpts = struct { maybe_null: bool = true, assume_capacity: bool = false };
        /// Push a child node onto the stack.
        /// - `maybe_null`: if true, the node will not be pushed if it is null. When false,
        ///   a runtime safety check is performed to ensure the node is not null.
        /// - `assume_capacity`: if true, the stack's capacity is assumed to be sufficient
        ///   for the new node, and this method will use `appendAssumeCapacity`. Useful for
        ///   pushing many nodes at once.
        inline fn push(self: *Self, node: Node.Index, comptime opts: PushOpts) if (opts.assume_capacity) void else Allocator.Error!void {
            if (comptime opts.maybe_null) {
                if (node == Semantic.NULL_NODE) return;
            }
            if (comptime util.RUNTIME_SAFETY) self.assertInRange(node);
            if (comptime opts.assume_capacity) {
                self.stack.appendAssumeCapacity(.{ .id = node, .kind = .exit });
                self.stack.appendAssumeCapacity(.{ .id = node, .kind = .enter });
            } else {
                try self.stack.append(self.alloc, .{ .id = node, .kind = .exit });
                return self.stack.append(self.alloc, .{ .id = node, .kind = .enter });
            }
        }

        /// Push many nodes, assuming none of them are null
        inline fn pushManyUnconditional(self: *Self, nodes: []const Node.Index) Allocator.Error!void {
            try self.ensureStackCapacity(nodes.len);
            var it = std.mem.reverseIterator(nodes);
            while (it.next()) |node| {
                self.assertInRange(node);
                self.stack.appendAssumeCapacity(.{ .id = node, .kind = .exit });
                self.stack.appendAssumeCapacity(.{ .id = node, .kind = .enter });
            }
        }

        /// Ensure unused capacity for `node_count` new nodes.
        inline fn ensureStackCapacity(self: *Self, node_count: usize) Allocator.Error!void {
            try self.stack.ensureUnusedCapacity(self.alloc, 2 * node_count);
        }

        /// Sanity check that is only enabled in safe/debug builds. Inlined so
        /// compiler can optimize away checks that aren't needed.
        inline fn assertInRange(self: *Self, node: Node.Index) void {
            util.assert(node != Semantic.NULL_NODE, "Tried to push null node onto stack", .{});

            if (comptime util.RUNTIME_SAFETY) {
                if (node >= self.ast.nodes.len) {
                    print(
                        "Tried to push out-of-bounds node (id: {d}, nodes.len: {d}). It's likely a token or extra_data index.",
                        .{ node, self.ast.nodes.len },
                    );
                    self.printStack();
                    @panic("node index out of bounds");
                }
            }

            if (comptime util.IS_DEBUG) self.checkForVisitLoop(node);
        }

        fn checkForVisitLoop(self: *const Self, node: Node.Index) void {
            @branchHint(.cold);
            for (self.stack.items) |seen| {
                if (seen.kind == .exit) continue;
                if (seen.id == node) {
                    print("\nFound a loop while walking an AST: Node {d} is already being visited.\n", .{node});
                    print("Stack:\n", .{});
                    self.printStack();
                    @panic("Tried to visit the same node twice.");
                }
            }
        }

        fn printStack(self: *const Self) void {
            const tags: []const Node.Tag = self.ast.nodes.items(.tag);
            print("Stack:\n", .{});
            for (self.stack.items) |el| {
                if (el.kind == .exit) continue;
                print("- {d}: {s}\n", .{ el.id, @tagName(tags[el.id]) });
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
        // NOTE: commented-out branches are covered by full node visitors
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
            // .global_var_decl => K.extra_node,
            // `var a: x align(y) = rhs`
            // lhs is the index into extra_data.
            // main_token is `var` or `const`.
            // .local_var_decl => K.extra_node,
            // `var a: lhs = rhs`. lhs and rhs may be unused.
            // Can be local or global.
            // main_token is `var` or `const`.
            // .simple_var_decl => K.node,
            // `var a align(lhs) = rhs`. lhs and rhs may be unused.
            // Can be local or global.
            // main_token is `var` or `const`.
            // .aligned_var_decl => K.node,
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
            // .array_type => K.node,
            // `[lhs:a]b`. `ArrayTypeSentinel[rhs]`.
            // .array_type_sentinel => K.node_extra,
            // `[*]align(lhs) rhs`. lhs can be omitted.
            // `*align(lhs) rhs`. lhs can be omitted.
            // `[]rhs`.
            // main_token is the asterisk if a pointer or the lbracket if a slice
            // main_token might be a ** token, which is shared with a parent/child
            // pointer type and may require special handling.
            // .ptr_type_aligned => K.node,
            // `[*:lhs]rhs`. lhs can be omitted.
            // `*rhs`.
            // `[:lhs]rhs`.
            // main_token is the asterisk if a pointer or the lbracket if a slice
            // main_token might be a ** token, which is shared with a parent/child
            // pointer type and may require special handling.
            // .ptr_type_sentinel => K.node,
            // lhs is index into ptr_type. rhs is the element type expression.
            // main_token is the asterisk if a pointer or the lbracket if a slice
            // main_token might be a ** token, which is shared with a parent/child
            // pointer type and may require special handling.
            // .ptr_type => K.extra_node,
            // lhs is index into ptr_type_bit_range. rhs is the element type expression.
            // main_token is the asterisk if a pointer or the lbracket if a slice
            // main_token might be a ** token, which is shared with a parent/child
            // pointer type and may require special handling.
            // .ptr_type_bit_range => K.extra_node,
            // `lhs[rhs..]`
            // main_token is the lbracket.
            // .slice_open => K.node_unconditional,
            // `lhs[b..c]`. rhs is index into Slice
            // main_token is the lbracket.
            // .slice => K.node_extra,
            // `lhs[b..c :d]`. rhs is index into SliceSentinel. Slice end "c" can be omitted.
            // main_token is the lbracket.
            // .slice_sentinel => K.node_extra,
            // `lhs.*`. rhs is unused.
            .deref => K.node_unset,
            // `lhs[rhs]`.
            .array_access => K.node_unconditional,
            // `lhs{rhs}`. rhs can be omitted.
            // .array_init_one => K.node,
            // `lhs{rhs,}`. rhs can *not* be omitted
            // .array_init_one_comma => K.node_unconditional,
            // `.{lhs, rhs}`. lhs and rhs can be omitted.
            // .array_init_dot_two => K.node,
            // Same as `array_init_dot_two` except there is known to be a trailing comma
            // before the final rbrace.
            // .array_init_dot_two_comma => K.node,
            // `.{a, b}`. `sub_list[lhs..rhs]`.
            // .array_init_dot => K.subrange,
            // Same as `array_init_dot` except there is known to be a trailing comma
            // before the final rbrace.
            // .array_init_dot_comma => K.subrange,
            // `lhs{a, b}`. `sub_range_list[rhs]`. lhs can be omitted which means `.{a, b}`.
            // .array_init => K.node_subrange,
            // Same as `array_init` except there is known to be a trailing comma
            // before the final rbrace.
            // .array_init_comma => K.node_subrange,
            // `lhs{.a = rhs}`. rhs can be omitted making it empty.
            // main_token is the lbrace.
            // .struct_init_one => K.node,
            // `lhs{.a = rhs,}`. rhs can *not* be omitted.
            // main_token is the lbrace.
            // .struct_init_one_comma => K.node_unconditional,
            // `.{.a = lhs, .b = rhs}`. lhs and rhs can be omitted.
            // main_token is the lbrace.
            // No trailing comma before the rbrace.
            // .struct_init_dot_two => K.node,
            // Same as `struct_init_dot_two` except there is known to be a trailing comma
            // before the final rbrace.
            // .struct_init_dot_two_comma => K.node,
            // `.{.a = b, .c = d}`. `sub_list[lhs..rhs]`.
            // main_token is the lbrace.
            // .struct_init_dot => K.subrange,
            // Same as `struct_init_dot` except there is known to be a trailing comma
            // before the final rbrace.
            // .struct_init_dot_comma => K.subrange,
            // `lhs{.a = b, .c = d}`. `sub_range_list[rhs]`.
            // lhs can be omitted which means `.{.a = b, .c = d}`.
            // main_token is the lbrace.
            // .struct_init => K.node_subrange,
            // Same as `struct_init` except there is known to be a trailing comma
            // before the final rbrace.
            // .struct_init_comma => K.node_subrange,
            // `lhs(rhs)`. rhs can be omitted.
            // main_token is the lparen.
            // .call_one => K.node,
            // `lhs(rhs,)`. rhs can be omitted.
            // main_token is the lparen.
            // .call_one_comma => K.node,
            // `async lhs(rhs)`. rhs can be omitted.
            // .async_call_one => K.node,
            // `async lhs(rhs,)`.
            // .async_call_one_comma => K.node,
            // `lhs(a, b, c)`. `SubRange[rhs]`.
            // main_token is the `(`.
            // .call => K.node_subrange,
            // `lhs(a, b, c,)`. `SubRange[rhs]`.
            // main_token is the `(`.
            // .call_comma => K.node_subrange,
            // `async lhs(a, b, c)`. `SubRange[rhs]`.
            // main_token is the `(`.
            // .async_call => K.node_subrange,
            // `async lhs(a, b, c,)`. `SubRange[rhs]`.
            // main_token is the `(`.
            // .async_call_comma => K.node_subrange,
            // `switch(lhs) {}`. `SubRange[rhs]`.
            .@"switch" => K.node_subrange,
            // Same as switch except there is known to be a trailing comma
            // before the final rbrace
            .switch_comma => K.node_subrange,
            // `lhs => rhs`. If lhs is omitted it means `else`.
            // main_token is the `=>`
            // .switch_case_one => K.node,
            // Same ast `switch_case_one` but the case is inline
            // .switch_case_inline_one => K.node,
            // `a, b, c => rhs`. `SubRange[lhs]`.
            // main_token is the `=>`
            // .switch_case => K.node_subrange,
            // Same ast `switch_case` but the case is inline
            // .switch_case_inline => K.node_subrange,
            // `lhs...rhs`.
            .switch_range => K.node_unconditional,
            // `while (lhs) rhs`.
            // `while (lhs) |x| rhs`.
            // .while_simple => K.node_unconditional,
            // `while (lhs) : (a) b`. `WhileCont[rhs]`.
            // `while (lhs) : (a) b`. `WhileCont[rhs]`.
            // .while_cont => K.node_extra,
            // `while (lhs) : (a) b else c`. `While[rhs]`.
            // `while (lhs) |x| : (a) b else c`. `While[rhs]`.
            // `while (lhs) |x| : (a) b else |y| c`. `While[rhs]`.
            // The cont expression part `: (a)` may be omitted.
            // .@"while" => K.node_extra,
            // `for (lhs) rhs`.
            // .for_simple => K.node,
            // `for (lhs[0..inputs]) lhs[inputs + 1] else lhs[inputs + 2]`. `For[rhs]`.
            // .@"for" => K.node_extra,
            // `lhs..rhs`. rhs can be omitted.
            .for_range => K.node,
            // `if (lhs) rhs`.
            // `if (lhs) |a| rhs`.
            // .if_simple => K.node_unconditional,
            // `if (lhs) a else b`. `If[rhs]`.
            // `if (lhs) |x| a else b`. `If[rhs]`.
            // `if (lhs) |x| a else |y| b`. `If[rhs]`.
            // .@"if" => K.node_extra,
            // `suspend lhs`. lhs can be omitted. rhs is unused.
            .@"suspend" => K.node_unset,
            // `resume lhs`. rhs is unused.
            .@"resume" => K.node_unset,
            // `continue`. lhs is token index of label if any. rhs is unused.
            .@"continue" => K.token_unset,
            // `break :lhs rhs`
            // both lhs and rhs may be omitted.
            .@"break" => K.token_node,
            // `return lhs`. lhs can be omitted. rhs is unused.
            .@"return" => K.node_unset,
            // `fn (a: lhs) rhs`. lhs can be omitted.
            // anytype and ... parameters are omitted from the AST tree.
            // main_token is the `fn` keyword.
            // extern function declarations use this tag.
            // .fn_proto_simple => K.node,
            // `fn (a: b, c: d) rhs`. `sub_range_list[lhs]`.
            // anytype and ... parameters are omitted from the AST tree.
            // main_token is the `fn` keyword.
            // extern function declarations use this tag.
            // .fn_proto_multi => K.node_subrange,
            // `fn (a: b) addrspace(e) linksection(f) callconv(g) rhs`. `FnProtoOne[lhs]`.
            // zero or one parameters.
            // anytype and ... parameters are omitted from the AST tree.
            // main_token is the `fn` keyword.
            // extern function declarations use this tag.
            // .fn_proto_one => K.extra_node,
            // `fn (a: b, c: d) addrspace(e) linksection(f) callconv(g) rhs`. `FnProto[lhs]`.
            // anytype and ... parameters are omitted from the AST tree.
            // main_token is the `fn` keyword.
            // extern function declarations use this tag.
            // .fn_proto => K.extra_node,
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
            // .container_decl => K.extra,
            // Same as ContainerDecl but there is known to be a trailing comma
            // or semicolon before the rbrace.
            // .container_decl_trailing => K.extra,
            // `struct {lhs, rhs}`, `union {lhs, rhs}`, `opaque {lhs, rhs}`, `enum {lhs, rhs}`.
            // lhs or rhs can be omitted.
            // main_token is `struct`, `union`, `opaque`, `enum` keyword.
            // .container_decl_two => K.node,
            // Same as ContainerDeclTwo except there is known to be a trailing comma
            // or semicolon before the rbrace.
            // .container_decl_two_trailing => K.node,
            // `struct(lhs)` / `union(lhs)` / `enum(lhs)`. `SubRange[rhs]`.
            // .container_decl_arg => K.node_subrange,
            // Same as container_decl_arg but there is known to be a trailing
            // comma or semicolon before the rbrace.
            // .container_decl_arg_trailing => K.node_subrange,
            // `union(enum) {}`. `sub_list[lhs..rhs]`.
            // Note that tagged unions with explicitly provided enums are represented
            // by `container_decl_arg`.
            // .tagged_union => K.subrange,
            // Same as tagged_union but there is known to be a trailing comma
            // or semicolon before the rbrace.
            // .tagged_union_trailing => K.subrange,
            // `union(enum) {lhs, rhs}`. lhs or rhs may be omitted.
            // Note that tagged unions with explicitly provided enums are represented
            // by `container_decl_arg`.
            // .tagged_union_two => K.node,
            // Same as tagged_union_two but there is known to be a trailing comma
            // or semicolon before the rbrace.
            // .tagged_union_two_trailing => K.node,
            // `union(enum(lhs)) {}`. `SubRange[rhs]`.
            // .tagged_union_enum_tag => K.node_subrange,
            // Same as tagged_union_enum_tag but there is known to be a trailing comma
            // or semicolon before the rbrace.
            // .tagged_union_enum_tag_trailing => K.node_subrange,
            // `a: lhs = rhs,`. lhs and rhs can be omitted.
            // main_token is the field name identifier.
            // lastToken() does not include the possible trailing comma.
            // .container_field_init => K.node,
            // `a: lhs align(rhs),`. rhs can be omitted.
            // main_token is the field name identifier.
            // lastToken() does not include the possible trailing comma.
            // .container_field_align => K.node,
            // `a: lhs align(c) = d,`. `container_field_list[rhs]`.
            // main_token is the field name identifier.
            // lastToken() does not include the possible trailing comma.
            // .container_field => K.node_extra,
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
            // .asm_simple => K.node_token,
            // `asm(lhs, a)`. `Asm[rhs]`.
            // .@"asm" => K.node_extra,
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
            else => unreachable, // covered by full node visitors
        };
    }
};

// toggle debug printing in walk(). Dont commit PRs with this still set to `true`.
const DEBUG_PRINT = false;
inline fn print(comptime fmt: []const u8, args: anytype) void {
    comptime if (!DEBUG_PRINT) return;
    std.debug.print(fmt ++ "\n", args);
}
comptime {
    if (@import("builtin").mode != .Debug) assert(DEBUG_PRINT == false);
}

const std = @import("std");
const util = @import("util");
const semantic = @import("../semantic.zig");
const mem = std.mem;
const assert = std.debug.assert;

const Allocator = mem.Allocator;
const Ast = std.zig.Ast;
const full = Ast.full;
const Node = Ast.Node;
const Semantic = semantic.Semantic;

// =============================================================================
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test {
    _ = @import("walk_test.zig");
}

test Walker {
    // This visitor has methods that get called during the walk.
    const Foo = struct {
        depth: u32 = 0,
        nodes_visited: u32 = 0,
        seen_fn_decl: bool = false,
        seen_var_decl: bool = false,

        const Error = error{};

        fn enterNode(self: *@This(), _: Node.Index) !void {
            self.depth += 1;
            self.nodes_visited += 1;
        }
        fn exitNode(self: *@This(), _: Node.Index) void {
            expect(self.depth > 0) catch @panic("expect failed");
            self.depth -= 1;
        }

        // All nodes may be visited with a function called `visit_[tag]`,
        // where `tag` is a variant of `Node.Tag`.
        fn visit_fn_decl(self: *@This(), _: Node.Index) Error!WalkState {
            self.seen_fn_decl = true;
            return .Continue;
        }

        /// You may also visit "full" nodes. Basically, if `Ast` has a method
        /// called `fullNodeKind`, then you can visit it with `visitNodeKind`.
        ///
        /// See `std.zig.Ast.full` for a list.
        fn visitVarDecl(
            self: *@This(),
            _: Node.Index,
            _: *const Ast.full.VarDecl,
        ) Error!WalkState {
            self.seen_var_decl = true;
            return .Continue;
        }
    };

    const allocator = std.testing.allocator;
    const src: [:0]const u8 =
        \\const std = @import("std");
        \\fn foo() void {
        \\  const x = 1;
        \\  std.debug.print("{d}\n", .{x});
        \\}
    ;

    // parse some source code into a std.zig.Ast
    var ast = try Ast.parse(allocator, src, .zig);
    defer ast.deinit(allocator);
    try expectEqual(0, ast.errors.len);

    // walk the AST with your visitor
    var visitor = Foo{};
    var walker = try Walker(Foo, Foo.Error).init(allocator, &ast, &visitor);
    defer walker.deinit();
    try walker.walk();

    try expectEqual(0, visitor.depth);
    try expectEqual(16, visitor.nodes_visited);
    try expect(visitor.seen_fn_decl);
    try expect(visitor.seen_var_decl);
}
