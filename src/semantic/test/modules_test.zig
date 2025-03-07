const std = @import("std");
const test_util = @import("util.zig");

const Symbol = @import("../Symbol.zig");
const Semantic = @import("../Semantic.zig");

const t = std.testing;
const build = test_util.build;
const panic = std.debug.panic;
const print = std.debug.print;

test "@import(\"std\")" {
    const src =
        \\const std = @import("std");
    ;
    var sema = try test_util.build(src);
    defer sema.deinit();
    try t.expectEqual(1, sema.modules.imports.items.len);
    const import = sema.modules.imports.items[0];
    try t.expectEqualStrings("std", import.specifier);
    try t.expectEqual(.module, import.kind);
    try t.expect(import.node != Semantic.NULL_NODE);
}

test "@import(\"foo.zig\")" {
    const src =
        \\const std = @import("foo.zig");
    ;
    var sema = try test_util.build(src);
    defer sema.deinit();
    try t.expectEqual(1, sema.modules.imports.items.len);
    const import = sema.modules.imports.items[0];
    try t.expectEqualStrings("foo.zig", import.specifier);
    try t.expectEqual(.file, import.kind);
    try t.expect(import.node != Semantic.NULL_NODE);
}
