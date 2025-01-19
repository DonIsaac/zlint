const std = @import("std");
const util = @import("util");
const semantic = @import("../semantic.zig");

const Ast = std.zig.Ast;
const string = util.string;
const Symbol = semantic.Symbol;
const Severity = @import("../Error.zig").Severity;
const Fix = @import("./fix.zig").Fix;

const LinterContext = @import("lint_context.zig");

pub const NodeWrapper = struct {
    node: *const Ast.Node,
    idx: Ast.Node.Index,

    pub inline fn getMainTokenOffset(self: *const NodeWrapper, ast: *const Ast) u32 {
        const starts = ast.tokens.items(.start);
        return starts[self.node.main_token];
    }
};

const RunOnNodeFn = *const fn (ptr: *const anyopaque, node: NodeWrapper, ctx: *LinterContext) anyerror!void;
const RunOnSymbolFn = *const fn (ptr: *const anyopaque, symbol: Symbol.Id, ctx: *LinterContext) anyerror!void;

/// A single lint rule.
///
/// ## Creating Rules
/// Rules are structs (or anything else that can have methods) that have 1 or
/// more of the following methods:
/// - `runOnNode(*self, node, *ctx)`
/// - `runOnSymbol(*self, symbol, *ctx)`
/// `Rule` provides a uniform interface to `Linter`. `Rule.init` will look for
/// those methods and, if they exist, stores pointers to them. These then get
/// used by the `Linter` to check for violations.
pub const Rule = struct {
    // name: string,
    meta: Meta,
    id: Id,
    ptr: *anyopaque,
    runOnNodeFn: RunOnNodeFn,
    runOnSymbolFn: RunOnSymbolFn,

    /// Rules must have a constant with this name of type `Rule.Meta`.
    const META_FIELD_NAME = "meta";
    pub const MAX_SIZE: usize = 16;
    pub const Meta = struct {
        name: string,
        category: Category,
        /// Default severity when no config file is provided. Rules that are
        /// `.off` do not get run at all.
        default: Severity = .off,
        /// Advertise auto-fixing capabilities to users.
        ///
        /// Used (in part) when generating documentation.
        fix: Fix.Meta = Fix.Meta.disabled,
    };

    pub const Category = enum {
        /// Re-implements a check already performed by the Zig compiler.
        compiler,
        correctness,
        suspicious,
        restriction,
        pedantic,
    };

    pub const WithSeverity = struct {
        rule: Rule,
        severity: Severity,
    };

    pub fn init(ptr: anytype) Rule {
        const T = @TypeOf(ptr);
        const ptr_info = comptime blk: {
            const info = @typeInfo(T);
            break :blk switch (info) {
                .Pointer => info.Pointer,
                else => @compileLog("Rule.init takes a pointer to a rule implementation, found an " ++ @tagName(info)),
            };
        };
        if (@sizeOf(ptr_info.child) > MAX_SIZE) {
            @compileError("Rule " ++ @typeName(ptr_info.child) ++ " is too large. Maximum size is " ++ MAX_SIZE);
        }
        const meta: Meta = if (@hasDecl(ptr_info.child, META_FIELD_NAME))
            @field(ptr_info.child, META_FIELD_NAME)
        else {
            @compileError("Rule must have a `pub const " ++ META_FIELD_NAME ++ " Rule.Meta` field");
        };

        const id = comptime rule_ids.get(meta.name) orelse @compileError("Could not find an id for rule '" ++ meta.name ++ "'.");

        const gen = struct {
            pub fn runOnNode(pointer: *const anyopaque, node: NodeWrapper, ctx: *LinterContext) anyerror!void {
                if (@hasDecl(ptr_info.child, "runOnNode")) {
                    const self: T = @ptrCast(@constCast(pointer));
                    return ptr_info.child.runOnNode(self, node, ctx);
                }
            }
            pub fn runOnSymbol(pointer: *const anyopaque, symbol: Symbol.Id, ctx: *LinterContext) anyerror!void {
                if (@hasDecl(ptr_info.child, "runOnSymbol")) {
                    const self: T = @ptrCast(@constCast(pointer));
                    return ptr_info.child.runOnSymbol(self, symbol, ctx);
                }
            }
        };

        return .{
            .id = id,
            .meta = meta,
            .ptr = ptr,
            .runOnNodeFn = gen.runOnNode,
            .runOnSymbolFn = gen.runOnSymbol,
        };
    }

    pub fn runOnNode(self: *const Rule, node: NodeWrapper, ctx: *LinterContext) !void {
        return self.runOnNodeFn(self.ptr, node, ctx);
    }

    pub fn runOnSymbol(self: *const Rule, symbol: Symbol.Id, ctx: *LinterContext) !void {
        return self.runOnSymbolFn(self.ptr, symbol, ctx);
    }

    pub fn getIdFor(name: []const u8) ?Rule.Id {
        return rule_ids.get(name);
    }

    pub const Id = util.NominalId(u32);
};

const IdMap = std.StaticStringMap(Rule.Id);
const rule_ids: IdMap = ids: {
    const Type = std.builtin.Type;
    const AllRules = @import("./rules.zig");
    const RuleDecls: []const Type.Declaration = @typeInfo(AllRules).Struct.decls;
    var ids: [RuleDecls.len]struct { []const u8, Rule.Id } = undefined;
    for (RuleDecls, 0..) |decl, i| {
        const RuleImpl = @field(AllRules, decl.name);
        if (!@hasDecl(RuleImpl, "meta")) {
            @compileError("Rule '" ++ decl.name ++ "' is missing a meta: Rule.Meta property.");
        }
        const name: []const u8 = @field(AllRules, decl.name).meta.name;
        const id = Rule.Id.new(i);
        ids[i] = .{ name, id };
    }
    break :ids IdMap.initComptime(ids);
};

test rule_ids {
    const t = std.testing;
    try t.expectEqual(
        @typeInfo(@import("./rules.zig")).Struct.decls.len,
        rule_ids.kvs.len,
    );
    try t.expect(rule_ids.get("unsafe-undefined") != null);
}
