const X = struct { field: ?u32 = 0 };
const Container = struct {
    foo: enum { a, b } = .a,
    bar: ?X = null,
};
