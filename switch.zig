
fn thingy(x: u32, y: u32) u32 {
    return switch (x) {
        1 => 1 + y,
        2 => y + 1,
        _ => 2,
    };
}
