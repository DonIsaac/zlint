const x = blk: {
    var y = 1;
    y += 2;
    break :blk y + 1;
};
