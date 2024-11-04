pub const Foo = enum {
    a,
    b,
    c,

    pub const Bar: u32 = 1;

    pub fn isNotA(self: Foo) bool {
        return self != Foo.a;
    }
};
