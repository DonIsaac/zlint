//! ## What This Rule Does
//!
//! Checks maximal blocks of top-level `const` declarations initialized with `@import`, including projected imports such as `@import("foo").Bar`.
//! Package imports sort before local imports, and each group sorts lexicographically by import specifier.
//! Local imports begin with `.` or end with `.zig`. Sorting is case-sensitive.
//! Attached comments move with their declaration; standalone comments, module documentation, and ZLint disable directives stay in place.
//!
//! ### Configuration
//!
//! `std_first` pins every import whose specifier is `std` to the start of its block.
//! `separated_groups` controls blank lines inside a block: `none` removes them, while `local` keeps one blank line before the local group.
//!
//! ```json
//! {
//!   "rules": {
//!     "sort-imports": ["warn", {
//!       "std_first": true,
//!       "separated_groups": "local"
//!     }]
//!   }
//! }
//! ```
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const a = @import("foo");
//! const z = @import("bar");
//!
//! const bar = @import("bar.zig");
//! const foo = @import("foo.zig");
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const z = @import("bar");
//! const a = @import("foo");
//! const bar = @import("bar.zig");
//! const foo = @import("foo.zig");
//! ```

const std = @import("std");
const util = @import("util");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const Fix = @import("../fix.zig").Fix;
const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);
const Allocator = std.mem.Allocator;

std_first: bool = false,
separated_groups: SeparatedGroups = .none,

const SortImports = @This();
pub const meta: Rule.Meta = .{
    .name = "sort-imports",
    .category = .style,
    .default = .off,
    .fix = .safe_fix,
};

const ImportKind = enum {
    package,
    local,
};

const SeparatedGroups = enum {
    none,
    local,
};

const Import = struct {
    span: Span,
    specifier: []const u8,
    kind: ImportKind,
    original_index: usize,
};

const BlockFixer = struct {
    span: Span,
    source: []const u8,
    imports: []Import,
    separated_groups: SeparatedGroups,
    newline: []const u8,

    fn apply(self: BlockFixer, builder: Fix.Builder) !Fix {
        if (std.ascii.indexOfIgnoreCase(self.span.snippet(self.source), "zlint-disable") != null) return builder.noop();
        var replacement = try render(
            builder.allocator,
            self.source,
            self.imports,
            self.separated_groups,
            self.newline,
        );
        errdefer replacement.deinit(builder.allocator);
        const owned = try replacement.toOwnedSlice(builder.allocator);
        return builder.replace(self.span, Cow.owned(owned, builder.allocator));
    }
};

pub fn runOnce(self: *const SortImports, ctx: *LinterContext) void {
    const declarations = ctx.ast().rootDecls();
    if (declarations.len < 2) return;

    var stack = std.heap.stackFallback(16 * @sizeOf(Import), ctx.gpa);
    const allocator = stack.get();
    var imports: std.ArrayListUnmanaged(Import) = .empty;
    defer imports.deinit(allocator);

    const source = ctx.source.text();
    for (declarations) |declaration| {
        if (collectImport(ctx, declaration, imports.items.len)) |entry| {
            if (imports.items.len > 0) {
                const previous = imports.items[imports.items.len - 1];
                if (hasUnattachedComment(source, previous.span.end, entry.span.start)) {
                    self.processBlock(ctx, imports.items);
                    imports.clearRetainingCapacity();
                }
            }
            imports.append(allocator, entry) catch @panic("OOM");
        } else if (imports.items.len > 0) {
            self.processBlock(ctx, imports.items);
            imports.clearRetainingCapacity();
        }
    }

    self.processBlock(ctx, imports.items);
}

fn collectImport(ctx: *LinterContext, declaration: Node.Index, original_index: usize) ?Import {
    const ast = ctx.ast();
    const var_decl = ast.fullVarDecl(declaration) orelse return null;
    if (ast.tokenTag(var_decl.ast.mut_token) != .keyword_const) return null;

    var import_node = var_decl.ast.init_node.unwrap() orelse return null;
    while (ast.nodeTag(import_node) == .field_access) {
        import_node = ast.nodeData(import_node).node_and_token[0];
    }
    if (ast.nodeTag(import_node) != .builtin_call_two and ast.nodeTag(import_node) != .builtin_call_two_comma) return null;
    if (!std.mem.eql(u8, ctx.semantic.tokenSlice(ast.nodeMainToken(import_node)), "@import")) return null;

    const specifier_node = ast.nodeData(import_node).opt_node_and_opt_node[0].unwrap() orelse return null;
    if (ast.nodeTag(specifier_node) != .string_literal) return null;

    const quoted_specifier = ctx.semantic.tokenSlice(ast.nodeMainToken(specifier_node));
    const specifier = std.mem.trim(u8, quoted_specifier, "\"");
    const source = ctx.source.text();
    const declaration_span = ctx.semantic.nodeSpan(declaration);
    const start = attachedCommentStart(source, declaration_span.start);
    const end = trailingCommentEnd(source, declarationEnd(source, declaration_span.end));

    return .{
        .span = Span.new(start, end),
        .specifier = specifier,
        .kind = importKind(specifier),
        .original_index = original_index,
    };
}

fn importKind(specifier: []const u8) ImportKind {
    const relative = specifier.len > 0 and specifier[0] == '.';
    return if (relative or std.mem.endsWith(u8, specifier, ".zig")) .local else .package;
}

fn declarationEnd(source: []const u8, node_end: u32) u32 {
    var cursor: u32 = node_end;
    while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
    return if (cursor < source.len and source[cursor] == ';') cursor + 1 else node_end;
}

fn trailingCommentEnd(source: []const u8, declaration_end: u32) u32 {
    const line_feed: u32 = @intCast(std.mem.indexOfScalarPos(u8, source, declaration_end, '\n') orelse source.len);
    const content_end: u32 = if (line_feed > 0 and source[line_feed - 1] == '\r') line_feed - 1 else line_feed;
    const trailing = std.mem.trim(u8, source[declaration_end..content_end], " \t");
    return if (std.mem.startsWith(u8, trailing, "//")) content_end else declaration_end;
}

fn attachedCommentStart(source: []const u8, declaration_start: u32) u32 {
    var start = declaration_start;
    var next_line = lineStart(source, declaration_start);
    while (next_line > 0) {
        var previous_end = next_line - 1;
        if (previous_end > 0 and source[previous_end - 1] == '\r') previous_end -= 1;
        const previous_start = lineStart(source, previous_end);
        const line = std.mem.trim(u8, source[previous_start..previous_end], " \t");
        if (!std.mem.startsWith(u8, line, "//")) break;
        if (std.mem.startsWith(u8, line, "//!") or std.ascii.indexOfIgnoreCase(line, "zlint-disable") != null) break;
        start = previous_start;
        next_line = previous_start;
    }
    return start;
}

fn lineStart(source: []const u8, position: u32) u32 {
    var start = position;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    return start;
}

fn hasUnattachedComment(source: []const u8, start: u32, end: u32) bool {
    return std.mem.indexOf(u8, source[start..end], "//") != null;
}

fn processBlock(self: *const SortImports, ctx: *LinterContext, imports: []Import) void {
    if (imports.len < 2) return;

    const span = Span.new(imports[0].span.start, imports[imports.len - 1].span.end);
    std.mem.sortUnstable(Import, imports, self, lessThan);
    const newline = blockNewline(ctx.source.text(), span);
    var expected = render(
        ctx.gpa,
        ctx.source.text(),
        imports,
        self.separated_groups,
        newline,
    ) catch @panic("OOM");
    defer expected.deinit(ctx.gpa);

    if (std.mem.eql(u8, span.snippet(ctx.source.text()), expected.items)) return;

    var diagnostic = ctx.diagnostic(
        "Import block is not sorted.",
        .{LabeledSpan.labeled(span, Cow.static("this import block is not sorted"))},
    );
    diagnostic.help = Cow.static("Sort package imports before local imports and alphabetically within each group.");
    ctx.reportWithFix(
        BlockFixer{
            .span = span,
            .source = ctx.source.text(),
            .imports = imports,
            .separated_groups = self.separated_groups,
            .newline = newline,
        },
        diagnostic,
        BlockFixer.apply,
    );
}

fn lessThan(self: *const SortImports, lhs: Import, rhs: Import) bool {
    if (self.std_first) {
        const lhs_is_std = std.mem.eql(u8, lhs.specifier, "std");
        const rhs_is_std = std.mem.eql(u8, rhs.specifier, "std");
        if (lhs_is_std != rhs_is_std) return lhs_is_std;
    }
    if (lhs.kind != rhs.kind) return lhs.kind == .package;
    if (!std.mem.eql(u8, lhs.specifier, rhs.specifier)) {
        return std.mem.lessThan(u8, lhs.specifier, rhs.specifier);
    }
    return lhs.original_index < rhs.original_index;
}

fn blockNewline(source: []const u8, span: Span) []const u8 {
    const block = span.snippet(source);
    const line_feed = std.mem.indexOfScalar(u8, block, '\n') orelse return "\n";
    return if (line_feed > 0 and block[line_feed - 1] == '\r') "\r\n" else "\n";
}

fn needsGroupSeparator(
    separated_groups: SeparatedGroups,
    previous: Import,
    current: Import,
) bool {
    return separated_groups == .local and previous.kind == .package and current.kind == .local;
}

fn render(
    allocator: Allocator,
    source: []const u8,
    imports: []const Import,
    separated_groups: SeparatedGroups,
    newline: []const u8,
) !std.ArrayListUnmanaged(u8) {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    var capacity: usize = 0;
    for (imports, 0..) |entry, index| {
        capacity += entry.span.len();
        if (index > 0) {
            capacity += newline.len;
            if (needsGroupSeparator(separated_groups, imports[index - 1], entry)) {
                capacity += newline.len;
            }
        }
    }
    try output.ensureTotalCapacity(allocator, capacity);

    for (imports, 0..) |entry, index| {
        if (index > 0) {
            try output.appendSlice(allocator, newline);
            if (needsGroupSeparator(separated_groups, imports[index - 1], entry)) {
                try output.appendSlice(allocator, newline);
            }
        }
        try output.appendSlice(allocator, entry.span.snippet(source));
    }
    return output;
}

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
        "const z = @import(\"bar\");\nconst a = @import(\"foo\");",
        "const bar = @import(\"bar.zig\");\nconst baz = @import(\"baz.zig\");\nconst foo = @import(\"foo.zig\");",
        "const z = @import(\"bar\");\nconst a = @import(\"foo\");\nconst bar = @import(\"bar.zig\");\nconst foo = @import(\"foo.zig\");",
        "//! Package docs.\n\nconst z = @import(\"bar\");\nconst a = @import(\"foo\");",
        "const relative = @import(\"./relative\");\nconst a = @import(\"a.zig\").A;\nconst z = @import(\"z.zig\").Z;",
        "pub const a = @import(\"a\");\npub const z = @import(\"z\");",
        "var z = @import(\"z\");\nvar a = @import(\"a\");",
        \\pub const a = @import(
        \\    "a",
        \\);
        \\pub const z = @import(
        \\    "z",
        \\);
        ,
        "const z = @import(\"z\");\n// standalone\n\nconst a = @import(\"a\");",
        \\fn main() void {
        \\    const z = @import("z.zig");
        \\    const a = @import("a.zig");
        \\}
        ,
        "const first = @import(\"same\");\nconst second = @import(\"same\");",
        "const b = @import(\"bar\");\n/// a docs\nconst a = @import(\"foo\");\nconst bar = @import(\"bar.zig\");\nconst foo = @import(\"foo.zig\");",
    };

    const fail = &[_][:0]const u8{
        "const std = @import(\"std\");\nconst z = @import(\"bar\");\nconst a = @import(\"foo\");",
        "const baz = @import(\"baz.zig\");\nconst bar = @import(\"bar.zig\");\nconst foo = @import(\"foo.zig\");",
        "const std = @import(\"std\");\nconst foo = @import(\"foo.zig\");\nconst baz = @import(\"baz\");\nconst bar = @import(\"bar.zig\");",
        "const baz = @import(\"baz\");\n\nconst bar = @import(\"bar.zig\");",
        "const a = @import(\"a\");\n\nconst b = @import(\"b\");",
        "const b = @import(\"b\");\nconst a = @import(\"a\");",
        "pub const z = @import(\"z\");\npub const a = @import(\"a\");",
        \\const z = @import(
        \\    "z",
        \\);
        \\const a = @import(
        \\    "a",
        \\);
        ,
        "const Z = @import(\"z.zig\").Z;\nconst A = @import(\"a.zig\").A;\nconst P = @import(\"p\").P;",
        "const z = @import(\"foo\"); // z\n/// a docs\nconst a = @import(\"bar\");",
        "const z = @import(\"foo\");\r\nconst a = @import(\"bar\");\r",
    };

    const fix = &[_]RuleTester.FixCase{
        .{
            .src = "const std = @import(\"std\");\nconst z = @import(\"bar\");\nconst a = @import(\"foo\");",
            .expected = "const z = @import(\"bar\");\nconst a = @import(\"foo\");\nconst std = @import(\"std\");",
        },
        .{
            .src = "const baz = @import(\"baz.zig\");\nconst bar = @import(\"bar.zig\");\nconst foo = @import(\"foo.zig\");",
            .expected = "const bar = @import(\"bar.zig\");\nconst baz = @import(\"baz.zig\");\nconst foo = @import(\"foo.zig\");",
        },
        .{
            .src = "const std = @import(\"std\");\nconst foo = @import(\"foo.zig\");\nconst baz = @import(\"baz\");\nconst bar = @import(\"bar.zig\");",
            .expected = "const baz = @import(\"baz\");\nconst std = @import(\"std\");\nconst bar = @import(\"bar.zig\");\nconst foo = @import(\"foo.zig\");",
        },
        .{
            .src = "const baz = @import(\"baz\");\n\nconst bar = @import(\"bar.zig\");",
            .expected = "const baz = @import(\"baz\");\nconst bar = @import(\"bar.zig\");",
        },
        .{
            .src = "const a = @import(\"a\");\n\nconst b = @import(\"b\");",
            .expected = "const a = @import(\"a\");\nconst b = @import(\"b\");",
        },
        .{
            .src = "const b = @import(\"b\");\nconst a = @import(\"a\");",
            .expected = "const a = @import(\"a\");\nconst b = @import(\"b\");",
        },
        .{
            .src = "pub const z = @import(\"z\");\npub const a = @import(\"a\");",
            .expected = "pub const a = @import(\"a\");\npub const z = @import(\"z\");",
        },
        .{
            .src = "const z = @import(\n    \"z\",\n);\nconst a = @import(\n    \"a\",\n);",
            .expected = "const a = @import(\n    \"a\",\n);\nconst z = @import(\n    \"z\",\n);",
        },
        .{
            .src = "const Z = @import(\"z.zig\").Z;\nconst A = @import(\"a.zig\").A;\nconst P = @import(\"p\").P;",
            .expected = "const P = @import(\"p\").P;\nconst A = @import(\"a.zig\").A;\nconst Z = @import(\"z.zig\").Z;",
        },
        .{
            .src = "const z = @import(\"foo\"); // z\n/// a docs\nconst a = @import(\"bar\");",
            .expected = "/// a docs\nconst a = @import(\"bar\");\nconst z = @import(\"foo\"); // z",
        },
        .{
            .src = "//! Package docs.\n\nconst z = @import(\"foo\");\nconst a = @import(\"bar\");",
            .expected = "//! Package docs.\n\nconst a = @import(\"bar\");\nconst z = @import(\"foo\");",
        },
        .{
            .src = "const z = @import(\"bar\"); const a = @import(\"foo\");",
            .expected = "const z = @import(\"bar\");\nconst a = @import(\"foo\");",
        },
        .{
            .src = "const z = @import(\"foo\");\nconst a = @import(\"bar\");",
            .expected = "const a = @import(\"bar\");\nconst z = @import(\"foo\");",
        },
        .{
            .src = "const z = @import(\"foo\"); // zlint-disable-next-line\nconst a = @import(\"bar\");",
            .expected = "",
            .fails_lint = true,
        },
        .{
            .src = "const z = @import(\"./z\");\nconst a = @import(\"./a\");",
            .expected = "const a = @import(\"./a\");\nconst z = @import(\"./z\");",
        },
        .{
            .src = "const Z = @import(\"z\").Z.B;\nconst A = @import(\"a\").A.B;",
            .expected = "const A = @import(\"a\").A.B;\nconst Z = @import(\"z\").Z.B;",
        },
        .{
            .src = "const z = @import(\"foo\");\r\nconst a = @import(\"bar\");\r",
            .expected = "const a = @import(\"bar\");\r\nconst z = @import(\"foo\");\r",
        },
        .{
            .src = "const z = @import(\"bar\");\nconst a = @import(\"foo\");\nfn separator() void {}\nconst y = @import(\"y.zig\");\nconst x = @import(\"x.zig\");",
            .expected = "const z = @import(\"bar\");\nconst a = @import(\"foo\");\nfn separator() void {}\nconst x = @import(\"x.zig\");\nconst y = @import(\"y.zig\");",
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}

test "std_first ordering" {
    var imports = [_]Import{
        .{ .span = .empty, .specifier = "z", .kind = .package, .original_index = 0 },
        .{ .span = .empty, .specifier = "std", .kind = .package, .original_index = 1 },
        .{ .span = .empty, .specifier = "local", .kind = .local, .original_index = 2 },
        .{ .span = .empty, .specifier = "a", .kind = .package, .original_index = 3 },
    };
    const sort_imports = SortImports{ .std_first = true };

    std.mem.sortUnstable(Import, imports[0..], &sort_imports, lessThan);

    try std.testing.expectEqualStrings("std", imports[0].specifier);
    try std.testing.expectEqualStrings("a", imports[1].specifier);
    try std.testing.expectEqualStrings("z", imports[2].specifier);
    try std.testing.expectEqualStrings("local", imports[3].specifier);
}

test "separated_groups rendering" {
    const source = "const z = @import(\"z\");\r\nconst bar = @import(\"./bar\");";
    const line_feed: u32 = @intCast(std.mem.indexOfScalar(u8, source, '\n').?);
    const first_end = line_feed - 1;
    const second_start = line_feed + 1;
    const imports = [_]Import{
        .{
            .span = Span.new(0, first_end),
            .specifier = "z",
            .kind = .package,
            .original_index = 0,
        },
        .{
            .span = Span.new(second_start, @intCast(source.len)),
            .specifier = "./bar",
            .kind = .local,
            .original_index = 1,
        },
    };

    var none = try render(std.testing.allocator, source, imports[0..], .none, "\r\n");
    defer none.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "const z = @import(\"z\");\r\nconst bar = @import(\"./bar\");",
        none.items,
    );

    var local = try render(std.testing.allocator, source, imports[0..], .local, "\r\n");
    defer local.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "const z = @import(\"z\");\r\n\r\nconst bar = @import(\"./bar\");",
        local.items,
    );
}
