//! ## What This Rule Does
//! Checks that top-level `@import` declarations are sorted.
//!
//! Imports are sorted within groups. A group is a run of consecutive `const`
//! declarations initialized with an `@import`, including field accesses on an
//! import (e.g. `const Allocator = @import("std").mem.Allocator;`). Blank
//! lines and other declarations end a group. Within each group, `@import("std")`
//! comes first, followed by other modules (e.g. `builtin` or dependencies),
//! followed by `.zig` and `.zon` files. Each of these sections is sorted
//! alphabetically by import path. Sorting is case-sensitive.
//!
//! Doc comments, comments directly above an import, and comments on the same
//! line as an import move with it when sorting. `zlint-disable` directives do
//! not move. To keep a header comment above a group, separate it from the
//! group's first import with a blank line.
//!
//! Imports nested inside functions or other containers are not checked.
//!
//! ### Sorting by Name
//! Set `sort_by` to `"name"` to sort each section by declaration name instead
//! of by import path.
//!
//! ```json
//! {
//!   "rules": {
//!     "sort-imports": ["warn", { "sort_by": "name" }]
//!   }
//! }
//! ```
//!
//! ### Blank Lines Between Sections
//! Set `newlines_between` to `"always"` to require a blank line between module
//! imports and file imports. The default, `"ignore"`, does not check blank
//! lines.
//!
//! ```json
//! {
//!   "rules": {
//!     "sort-imports": ["warn", { "newlines_between": "always" }]
//!   }
//! }
//! ```
//!
//! ```zig
//! const std = @import("std");
//! const clap = @import("clap");
//!
//! const foo = @import("foo.zig");
//! ```
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const foo = @import("foo.zig");
//! const std = @import("std");
//!
//! const bar = @import("bar.zig");
//! const baz = @import("baz");
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const std = @import("std");
//! const builtin = @import("builtin");
//! const clap = @import("clap");
//! const foo = @import("foo.zig");
//!
//! // groups are sorted independently
//! const baz = @import("baz");
//! const bar = @import("bar.zig");
//! ```

const std = @import("std");
const util = @import("util");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const disable_directives = @import("../disable_directives.zig");

const Span = _span.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const Fix = @import("../fix.zig").Fix;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const ImportKind = Semantic.ModuleRecord.ImportEntry.Kind;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

sort_by: SortBy = .specifier,
newlines_between: NewlinesBetween = .ignore,

const SortImports = @This();
pub const meta: Rule.Meta = .{
    .name = "sort-imports",
    .category = .style,
    .default = .warning,
    .fix = Fix.Meta.safe_fix,
};

pub const SortBy = enum {
    /// Sort by the string passed to `@import`.
    specifier,
    /// Sort by the name of the declaration an import is bound to.
    name,
};

pub const NewlinesBetween = enum {
    /// Do not check blank lines between sections.
    ignore,
    /// Require a blank line between module imports and file imports.
    always,
};

const Import = struct {
    /// The import's declaration, including attached comments.
    span: Span,
    decl: Node.Index,
    specifier: []const u8,
    name: []const u8,
    kind: ImportKind,

    fn isStd(self: Import) bool {
        return std.mem.eql(u8, self.specifier, "std");
    }

    fn lessThan(sort_by: SortBy, a: Import, b: Import) bool {
        const a_std = a.isStd();
        if (a_std != b.isStd()) return a_std;
        if (a.kind != b.kind) return a.kind == .module;
        const a_name, const b_name = .{ unquoted(a.name), unquoted(b.name) };
        const a_key, const a_tiebreak, const b_key, const b_tiebreak = switch (sort_by) {
            .specifier => .{ a.specifier, a_name, b.specifier, b_name },
            .name => .{ a_name, a.specifier, b_name, b.specifier },
        };
        return switch (std.mem.order(u8, a_key, b_key)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.lessThan(u8, a_tiebreak, b_tiebreak),
        };
    }

    /// `@"foo"` -> `foo`
    fn unquoted(identifier: []const u8) []const u8 {
        return if (std.mem.startsWith(u8, identifier, "@\""))
            identifier[2 .. identifier.len - 1]
        else
            identifier;
    }

    fn hasTrailingComment(self: Import, source: []const u8) bool {
        return source[self.span.end - 1] != ';';
    }
};

fn unsortedDiagnostic(ctx: *LinterContext, sort_by: SortBy, curr: Import, prev: Import) Error {
    var e = ctx.diagnostic(
        "Imports are not sorted.",
        .{ctx.labelN(curr.decl, "`{s}` should come before `{s}`", .{ curr.name, prev.name })},
    );
    const help = "Sort `std` first, then other modules, then files. Sort each section by ";
    e.help = switch (sort_by) {
        .specifier => Cow.static(help ++ "import path."),
        .name => Cow.static(help ++ "declaration name."),
    };
    return e;
}

fn missingNewlineDiagnostic(ctx: *LinterContext, first_file: Import) Error {
    var e = ctx.diagnostic(
        "Module and file imports are not separated by a blank line.",
        .{ctx.labelN(first_file.decl, "expected a blank line before `{s}`", .{first_file.name})},
    );
    e.help = Cow.static("Add a blank line between module imports and file imports.");
    return e;
}

pub fn runOnce(self: *const SortImports, ctx: *LinterContext) void {
    const imports = ctx.semantic.modules.imports.items;
    if (imports.len < 2) return;

    const source = ctx.source.text();
    const tok_tags: []const Semantic.Token.Tag = ctx.ast().tokens.items(.tag);
    const comments = Comments{
        .source = source,
        .starts = ctx.semantic.comments().items(.start),
        .ends = ctx.semantic.comments().items(.end),
    };

    var stackfb_buf: [16 * @sizeOf(Import)]u8 = undefined;
    var stackfb: std.heap.BufferFirstAllocator = .init(&stackfb_buf, ctx.gpa);
    const alloc = stackfb.allocator();
    var group: std.ArrayList(Import) = .empty;
    defer group.deinit(alloc);

    for (imports) |entry| {
        const decl, const var_decl = importDecl(ctx, entry.node) orelse continue;

        var first_tok = var_decl.firstToken();
        while (first_tok > 0 and tok_tags[first_tok - 1] == .doc_comment) first_tok -= 1;
        const semicolon = ctx.ast().lastToken(decl) + 1;
        util.debugAssert(tok_tags[semicolon] == .semicolon, "expected container-level declaration to end with a semicolon", .{});

        const item: Import = .{
            .span = .new(
                comments.leadingStart(ctx.semantic.tokenSpan(first_tok).start),
                comments.trailingEnd(ctx.semantic.tokenSpan(semicolon).end),
            ),
            .decl = decl,
            .specifier = entry.specifier,
            .name = ctx.semantic.tokenSlice(var_decl.ast.mut_token + 1),
            .kind = entry.kind,
        };

        // a group continues when only a single newline separates imports
        if (group.getLastOrNull()) |prev| {
            const gap = source[prev.span.end..item.span.start];
            if (std.mem.indexOfNone(u8, gap, &std.ascii.whitespace) != null or std.mem.count(u8, gap, "\n") > 1) {
                self.checkGroup(ctx, group.items);
                group.clearRetainingCapacity();
            }
        }
        group.append(alloc, item) catch @panic("OOM");
    }

    self.checkGroup(ctx, group.items);
}

/// Get the top-level `const` declaration initialized by an `@import` node, if
/// there is one.
fn importDecl(ctx: *const LinterContext, import_node: Node.Index) ?struct { Node.Index, Ast.full.VarDecl } {
    const ast = ctx.ast();
    const links = ctx.links();

    var init_node = import_node;
    var parent = links.getParent(import_node) orelse return null;
    while (ast.nodeTag(parent) == .field_access) {
        init_node = parent;
        parent = links.getParent(parent) orelse return null;
    }
    if ((links.getParent(parent) orelse return null) != .root) return null;

    const var_decl = ast.fullVarDecl(parent) orelse return null;
    if (ast.tokenTag(var_decl.ast.mut_token) != .keyword_const) return null;
    if (var_decl.ast.init_node.unwrap() != init_node) return null;
    return .{ parent, var_decl };
}

/// Finds comments attached to an import.
const Comments = struct {
    source: []const u8,
    /// Sorted by position in `source`.
    starts: []const u32,
    ends: []const u32,

    /// Get the start of the comments on the lines directly above `decl_start`.
    /// Global disable directives are not attached.
    fn leadingStart(self: Comments, decl_start: u32) u32 {
        var parser = disable_directives.Parser.new(self.source);
        var start = decl_start;
        var i = self.firstAtOrAfter(decl_start);
        while (i > 0) {
            i -= 1;
            const comment: Span = .new(self.starts[i], self.ends[i]);
            const between = self.source[comment.end..start];
            if (std.mem.indexOfNone(u8, between, &std.ascii.whitespace) != null or std.mem.count(u8, between, "\n") != 1) break;
            const line_start = if (std.mem.lastIndexOfScalar(u8, self.source[0..comment.start], '\n')) |nl| nl + 1 else 0;
            if (std.mem.indexOfNone(u8, self.source[line_start..comment.start], " \t") != null) break;
            if (parser.parse(comment)) |directive| {
                if (directive.isGlobal()) break;
            }
            start = comment.start;
        }
        return start;
    }

    /// Get the end of a comment on the same line as, and after, an import's
    /// semicolon. Returns `semicolon_end` if there is no such comment.
    fn trailingEnd(self: Comments, semicolon_end: u32) u32 {
        const i = self.firstAtOrAfter(semicolon_end);
        if (i == self.starts.len) return semicolon_end;
        if (std.mem.indexOfNone(u8, self.source[semicolon_end..self.starts[i]], " \t") != null) return semicolon_end;
        const comment = std.mem.trimEnd(u8, self.source[self.starts[i]..self.ends[i]], &std.ascii.whitespace);
        return self.starts[i] + @as(u32, @intCast(comment.len));
    }

    fn firstAtOrAfter(self: Comments, offset: u32) usize {
        return std.sort.lowerBound(u32, self.starts, offset, struct {
            fn order(target: u32, start: u32) std.math.Order {
                return std.math.order(target, start);
            }
        }.order);
    }
};

fn checkGroup(self: *const SortImports, ctx: *LinterContext, group: []const Import) void {
    if (group.len < 2) return;
    const fix = GroupFix{
        .group = group,
        .sort_by = self.sort_by,
        .split = self.newlines_between == .always,
        .source = ctx.source.text(),
    };
    for (group[1..], group[0 .. group.len - 1]) |curr, prev| {
        if (!Import.lessThan(self.sort_by, curr, prev)) continue;
        ctx.reportWithFix(fix, unsortedDiagnostic(ctx, self.sort_by, curr, prev), &GroupFix.sort);
        return;
    }

    // a blank line ends a group, so a sorted group containing both modules and files is missing one
    if (!fix.split) return;
    const first_file = GroupFix.firstFile(group) orelse return;
    ctx.reportWithFix(fix, missingNewlineDiagnostic(ctx, group[first_file]), &GroupFix.sort);
}

const GroupFix = struct {
    group: []const Import,
    sort_by: SortBy,
    /// Insert a blank line between module and file imports.
    split: bool,
    source: []const u8,

    /// Index of the first file import in a sorted group, if it is preceded by
    /// a module import.
    fn firstFile(sorted: []const Import) ?usize {
        if (sorted[0].kind == .file) return null;
        for (sorted[1..], 1..) |item, i| {
            if (item.kind == .file) return i;
        }
        return null;
    }

    /// Reorder imports, keeping the text between them in place.
    fn sort(self: GroupFix, builder: Fix.Builder) !Fix {
        const group = self.group;
        const span: Span = .new(group[0].span.start, group[group.len - 1].span.end);

        const sorted = try builder.allocator.dupe(Import, group);
        defer builder.allocator.free(sorted);
        std.mem.sort(Import, sorted, self.sort_by, Import.lessThan);

        // the separator before this import is replaced with a blank line
        const split_at: usize = if (self.split) firstFile(sorted) orelse 0 else 0;

        // moving a trailing comment in front of an import on the same line would comment it out
        for (sorted[0 .. group.len - 1], group[0 .. group.len - 1], group[1..], 1..) |item, before, after, i| {
            if (i == split_at) continue;
            const separator = self.source[before.span.end..after.span.start];
            if (item.hasTrailingComment(self.source) and std.mem.indexOfScalar(u8, separator, '\n') == null) {
                return builder.noop();
            }
        }

        var len: usize = span.len();
        var eol: []const u8 = "\n";
        if (split_at != 0) {
            const separator = self.source[group[split_at - 1].span.end..group[split_at].span.start];
            if (lineEnding(separator) orelse lineEnding(self.source)) |e| eol = e;
            len = len - separator.len + 2 * eol.len;
        }

        const fixed = try builder.allocator.alloc(u8, len);
        errdefer builder.allocator.free(fixed);
        var cursor: usize = 0;
        for (sorted, 0..) |item, i| {
            const text = item.span.snippet(self.source);
            @memcpy(fixed[cursor..][0..text.len], text);
            cursor += text.len;
            if (i + 1 == group.len) break;
            if (i + 1 == split_at) {
                for (0..2) |_| {
                    @memcpy(fixed[cursor..][0..eol.len], eol);
                    cursor += eol.len;
                }
                continue;
            }
            const separator = self.source[group[i].span.end..group[i + 1].span.start];
            @memcpy(fixed[cursor..][0..separator.len], separator);
            cursor += separator.len;
        }
        util.assert(cursor == fixed.len, "sorted imports ({d} bytes) do not fill the fixed span ({d} bytes)", .{ cursor, fixed.len });

        return builder.replace(span, Cow.owned(fixed, builder.allocator));
    }

    /// Get the first line ending in `text`.
    fn lineEnding(text: []const u8) ?[]const u8 {
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
        return if (nl > 0 and text[nl - 1] == '\r') "\r\n" else "\n";
    }
};

pub fn rule(self: *SortImports) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test SortImports {
    const t = std.testing;

    var sort_imports = SortImports{};
    var runner = RuleTester.init(t.allocator, sort_imports.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "const x = 1;",
        "const std = @import(\"std\");",
        \\const std = @import("std");
        \\const bar = @import("bar");
        \\const builtin = @import("builtin");
        \\const a = @import("a.zig");
        \\const b = @import("b.zon");
        ,
        \\const Allocator = @import("std").mem.Allocator;
        \\const std = @import("std");
        ,
        \\const A = @import("a.zig").A;
        \\const B = @import("a.zig").B;
        ,
        // groups are sorted independently
        \\const z = @import("z");
        \\
        \\const a = @import("a");
        ,
        \\const z = @import("z");
        \\const x = 1;
        \\const a = @import("a");
        ,
        \\const z = @import("z.zig");
        \\fn foo() void {}
        \\const a = @import("a.zig");
        ,
        // comments on their own line do not break groups, but blank lines do
        \\const z = @import("z");
        \\// a comment
        \\
        \\const a = @import("a");
        ,
        \\const a = @import("a");
        \\// a comment
        \\const z = @import("z");
        ,
        // sorting is case-sensitive
        \\const B = @import("B");
        \\const a = @import("a");
        ,
        \\pub const a = @import("a");
        \\const z = @import("z");
        ,
        // only top-level `const` declarations are checked
        \\var z = @import("z");
        \\var a = @import("a");
        ,
        \\fn foo() void {
        \\    const z = @import("z");
        \\    const a = @import("a");
        \\    _ = z;
        \\    _ = a;
        \\}
        ,
        \\const Foo = struct {
        \\    const z = @import("z");
        \\    const a = @import("a");
        \\};
        ,
        \\const z: @import("z").T = undefined;
        \\const a: @import("a").T = undefined;
        ,
        \\const z = @import("z").foo();
        \\const a = @import("a").foo();
        ,
        \\const std = @import("std");
        \\
        \\pub fn main() void {}
        \\
        \\const a = @import("a.zig");
        \\const b = @import("b.zig");
        ,
    };

    const fail = &[_][:0]const u8{
        \\const foo = @import("foo.zig");
        \\const std = @import("std");
        ,
        \\const z = @import("z");
        \\const a = @import("a");
        ,
        \\const bar = @import("bar.zig");
        \\const baz = @import("baz");
        ,
        \\const builtin = @import("builtin");
        \\const std = @import("std");
        ,
        \\const std = @import("std");
        \\const a = @import("a.zig");
        \\const b = @import("b");
        ,
        \\const B = @import("a.zig").B;
        \\const A = @import("a.zig").A;
        ,
        \\pub const z = @import("z");
        \\const a = @import("a");
        ,
        // one diagnostic per group
        \\const z = @import("z");
        \\const a = @import("a");
        \\
        \\const y = @import("y");
        \\const b = @import("b");
        ,
        \\const z = @import(
        \\    "z",
        \\);
        \\const a = @import(
        \\    "a",
        \\);
        ,
        \\const z = @import("z"); const a = @import("a");
        ,
        \\const Foo = struct {};
        \\const z = @import("z");
        \\const a = @import("a");
        ,
    };

    const fix = &[_]RuleTester.FixCase{
        .{
            .src =
            \\const foo = @import("foo.zig");
            \\const std = @import("std");
            \\const baz = @import("baz");
            \\const bar = @import("bar.zig");
            ,
            .expected =
            \\const std = @import("std");
            \\const baz = @import("baz");
            \\const bar = @import("bar.zig");
            \\const foo = @import("foo.zig");
            ,
        },
        // blank lines and the code around a group are preserved
        .{
            .src =
            \\//! Module docs
            \\
            \\const z = @import("z");
            \\const a = @import("a");
            \\
            \\const y = @import("y.zig");
            \\const b = @import("b.zig");
            \\
            \\pub fn main() void {}
            \\
            ,
            .expected =
            \\//! Module docs
            \\
            \\const a = @import("a");
            \\const z = @import("z");
            \\
            \\const b = @import("b.zig");
            \\const y = @import("y.zig");
            \\
            \\pub fn main() void {}
            \\
            ,
        },
        // doc comments, comments above, and trailing comments move with their import
        .{
            .src =
            \\/// z docs
            \\const z = @import("z"); // z trailing
            \\// a comment
            \\/// a docs
            \\const a = @import("a"); // a trailing
            ,
            .expected =
            \\// a comment
            \\/// a docs
            \\const a = @import("a"); // a trailing
            \\/// z docs
            \\const z = @import("z"); // z trailing
            ,
        },
        // global disable directives stay in place
        .{
            .src =
            \\// zlint-disable no-unresolved
            \\// z comment
            \\const z = @import("z");
            \\const a = @import("a");
            ,
            .expected =
            \\// zlint-disable no-unresolved
            \\const a = @import("a");
            \\// z comment
            \\const z = @import("z");
            ,
        },
        .{
            .src =
            \\// zlint-disable-next-line no-unresolved
            \\const z = @import("z");
            \\const a = @import("a");
            ,
            .expected =
            \\const a = @import("a");
            \\// zlint-disable-next-line no-unresolved
            \\const z = @import("z");
            ,
        },
        .{
            .src =
            \\const z = @import("z"); // zlint-disable-line no-unresolved
            \\const a = @import("a");
            ,
            .expected =
            \\const a = @import("a");
            \\const z = @import("z"); // zlint-disable-line no-unresolved
            ,
        },
        // a blank line keeps a header in place
        .{
            .src =
            \\// header
            \\
            \\const z = @import("z");
            \\const a = @import("a");
            ,
            .expected =
            \\// header
            \\
            \\const a = @import("a");
            \\const z = @import("z");
            ,
        },
        .{
            .src =
            \\const x = 1; // x
            \\// z comment
            \\const z = @import("z");
            \\const a = @import("a");
            ,
            .expected =
            \\const x = 1; // x
            \\const a = @import("a");
            \\// z comment
            \\const z = @import("z");
            ,
        },
        .{
            .src =
            \\const Z = @import("z").Z;
            \\pub const A = @import("a").A.B;
            ,
            .expected =
            \\pub const A = @import("a").A.B;
            \\const Z = @import("z").Z;
            ,
        },
        .{
            .src =
            \\const z = @import(
            \\    "z",
            \\);
            \\const a = @import("a");
            ,
            .expected =
            \\const a = @import("a");
            \\const z = @import(
            \\    "z",
            \\);
            ,
        },
        .{
            .src = "const z = @import(\"z\"); const a = @import(\"a\");",
            .expected = "const a = @import(\"a\"); const z = @import(\"z\");",
        },
        .{
            .src = "const z = @import(\"z\"); // z\r\nconst a = @import(\"a\");\r\n",
            .expected = "const a = @import(\"a\");\r\nconst z = @import(\"z\"); // z\r\n",
        },
        .{
            .src = "const z = @import(\"z\");\r\n\r\nconst b = @import(\"b\");\r\nconst a = @import(\"a\");\r\n",
            .expected = "const z = @import(\"z\");\r\n\r\nconst a = @import(\"a\");\r\nconst b = @import(\"b\");\r\n",
        },
        .{
            .src = "const z = @import(\"z\"); const a = @import(\"a\"); // a",
            .expected = "",
            .fails_lint = true,
        },
        .{
            .src =
            \\const b = @import("b"); // b
            \\const a = @import("a"); const c = @import("c");
            ,
            .expected = "",
            .fails_lint = true,
        },
        // separators keep their position, not their import
        .{
            .src =
            \\const c = @import("c");
            \\const b = @import("b"); const a = @import("a");
            ,
            .expected =
            \\const a = @import("a");
            \\const b = @import("b"); const c = @import("c");
            ,
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}

test "SortImports: sort_by name" {
    const t = std.testing;

    var sort_imports = SortImports{ .sort_by = .name };
    var runner = RuleTester.init(t.allocator, sort_imports.rule());
    runner.snapshot_name = "sort-imports-by-name";
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        \\const std = @import("std");
        \\const hello = @import("stuff");
        \\const there = @import("something");
        \\const bar = @import("z.zig");
        \\const foo = @import("a.zig");
        ,
        \\const Allocator = @import("std").mem.Allocator;
        \\const std = @import("std");
        ,
        \\const A = @import("b.zig").A;
        \\const B = @import("a.zig").B;
        ,
        \\const Alpha = @import("z");
        \\const @"beta" = @import("b");
        \\const gamma = @import("a");
        ,
    };

    const fail = &[_][:0]const u8{
        \\const @"zeta" = @import("a");
        \\const Alpha = @import("z");
        ,
        \\const there = @import("something");
        \\const hello = @import("stuff");
        \\const bar = @import("z.zig");
        ,
        \\const foo = @import("a.zig");
        \\const bar = @import("z.zig");
        ,
    };

    const fix = &[_]RuleTester.FixCase{
        .{
            .src =
            \\const there = @import("something");
            \\const foo = @import("a.zig");
            \\const hello = @import("stuff");
            \\const std = @import("std");
            ,
            .expected =
            \\const std = @import("std");
            \\const hello = @import("stuff");
            \\const there = @import("something");
            \\const foo = @import("a.zig");
            ,
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}

test "SortImports: newlines_between always" {
    const t = std.testing;

    var sort_imports = SortImports{ .newlines_between = .always };
    var runner = RuleTester.init(t.allocator, sort_imports.rule());
    runner.snapshot_name = "sort-imports-newlines-between";
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        \\const std = @import("std");
        \\const baz = @import("baz");
        \\
        \\const bar = @import("bar.zig");
        \\const foo = @import("foo.zig");
        ,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const clap = @import("clap");
        ,
        \\const a = @import("a.zig");
        \\const b = @import("b.zon");
        ,
        \\const std = @import("std");
        \\// a comment
        \\
        \\const a = @import("a.zig");
        ,
        // files before modules in separate groups are not checked
        \\const a = @import("a.zig");
        \\
        \\const std = @import("std");
        ,
    };

    const fail = &[_][:0]const u8{
        \\const std = @import("std");
        \\const foo = @import("foo.zig");
        \\const baz = @import("baz");
        \\const bar = @import("bar.zig");
        ,
        \\const std = @import("std");
        \\const baz = @import("baz");
        \\const bar = @import("bar.zig");
        ,
        "const a = @import(\"a\"); const b = @import(\"b.zig\");",
    };

    const fix = &[_]RuleTester.FixCase{
        .{
            .src =
            \\const std = @import("std");
            \\const foo = @import("foo.zig");
            \\const baz = @import("baz");
            \\const bar = @import("bar.zig");
            ,
            .expected =
            \\const std = @import("std");
            \\const baz = @import("baz");
            \\
            \\const bar = @import("bar.zig");
            \\const foo = @import("foo.zig");
            ,
        },
        .{
            .src =
            \\const std = @import("std");
            \\const bar = @import("bar.zig");
            \\
            \\pub fn main() void {}
            ,
            .expected =
            \\const std = @import("std");
            \\
            \\const bar = @import("bar.zig");
            \\
            \\pub fn main() void {}
            ,
        },
        // comments move with their import
        .{
            .src =
            \\/// bar docs
            \\const bar = @import("bar.zig"); // bar
            \\const std = @import("std"); // std
            ,
            .expected =
            \\const std = @import("std"); // std
            \\
            \\/// bar docs
            \\const bar = @import("bar.zig"); // bar
            ,
        },
        .{
            .src = "const a = @import(\"a\"); const b = @import(\"b.zig\");",
            .expected = "const a = @import(\"a\");\n\nconst b = @import(\"b.zig\");",
        },
        .{
            .src = "const std = @import(\"std\");\r\nconst a = @import(\"a.zig\");\r\n",
            .expected = "const std = @import(\"std\");\r\n\r\nconst a = @import(\"a.zig\");\r\n",
        },
        .{
            .src = "const x = 1;\r\nconst a = @import(\"a\"); const b = @import(\"b.zig\");\r\n",
            .expected = "const x = 1;\r\nconst a = @import(\"a\");\r\n\r\nconst b = @import(\"b.zig\");\r\n",
        },
        // the separator after a trailing comment is replaced, so the fix is safe
        .{
            .src =
            \\const b = @import("b.zig"); const a = @import("a"); // a
            ,
            .expected =
            \\const a = @import("a"); // a
            \\
            \\const b = @import("b.zig");
            ,
        },
        .{
            .src =
            \\const b = @import("b"); // b
            \\const a = @import("a"); const c = @import("c.zig");
            ,
            .expected =
            \\const a = @import("a");
            \\const b = @import("b"); // b
            \\
            \\const c = @import("c.zig");
            ,
        },
        .{
            .src =
            \\const b = @import("b.zig"); const z = @import("z"); const a = @import("a"); // a
            ,
            .expected = "",
            .fails_lint = true,
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}
