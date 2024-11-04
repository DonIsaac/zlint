a: u32,
b: []const u8 = "",

const Foo = @This();

pub fn new() Foo {
    return Foo{ .a = 0, .b = "hello" };
}
