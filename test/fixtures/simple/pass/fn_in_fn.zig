pub fn foo(a: u32) u32 {
    const inner = struct {
        fn bar(b: u32) u32 {
            return b + 1;
        }
    };

    return inner.bar(a);
}
