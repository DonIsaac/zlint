const x = u64;
const Foo = struct { u32, i32, x };
const Namespace = struct {
    const Member = u32;
};
const Bar = struct { Namespace.Member };

const f: Foo = .{ 1, 2, 3 };
