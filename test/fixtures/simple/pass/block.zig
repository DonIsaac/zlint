fn empty() void {
    const x = {};
    return x;
}

fn one() void {
    var y = 1;
    {
        y = 1;
    }
}

fn two() void {
    var z = 1;
    {
        const a = 1;
        z = a;
    }
}

fn many() void {
    var a = 1;
    {
        const b = 1;
        const c = 2;
        const d = 3;
        const e = 4;
        const f = 5;
        a += b + c + d + e + f;
    }
}
