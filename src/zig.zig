pub const @"0.14.1" = struct {
    pub const Ast = @import("zig/0.14.1/Ast.zig");
    pub const Parse = @import("zig/0.14.1/Parse.zig");
    pub const Token = @import("zig/0.14.1/tokenizer.zig").Token;
    pub const Tokenizer = @import("zig/0.14.1/tokenizer.zig").Tokenizer;
    pub const primitives = @import("zig/0.14.1/primitives.zig");
    pub const string_literal = @import("zig/0.14.1/string_literal.zig");
};
