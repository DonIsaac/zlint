// NOTE:
// This is a copy/paste of pieces from `std.zig` from v0.14.1
// MIT license. See `src/zig/0.14.1/LICENSE` for details.
pub const @"0.14.1" = struct {
    pub const Ast = @import("zig/0.14.1/Ast.zig");
    pub const Parse = @import("zig/0.14.1/Parse.zig");
    pub const Token = @import("zig/0.14.1/tokenizer.zig").Token;
    pub const Tokenizer = @import("zig/0.14.1/tokenizer.zig").Tokenizer;
    pub const primitives = @import("zig/0.14.1/primitives.zig");
    pub const string_literal = @import("zig/0.14.1/string_literal.zig");
};
