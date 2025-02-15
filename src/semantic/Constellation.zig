const Constellation = @This();
const GPA_ARENA_SIZE = 4;
const SafeGPA = GeneralPurposeAllocator(.{
    .never_unmap = util.IS_DEBUG,
    .retain_metadata = util.IS_DEBUG,
});

// TODO: use Dora
bundles: std.AutoHashMapUnmanaged(SourceBundle.Id, SourceBundle),
next_id: atomic.Value(u32) = .{ .raw = 0 },
allocator: Allocator,
/// GPAs are bucketed to reduce contention over GPA mutex when SourceBundles
/// allocate.
gpa_arena: [*]SafeGPA,

pub fn init(allocator: Allocator) Allocator.Error!Constellation {
    var gpa_arena = try allocator.alloc(SafeGPA, GPA_ARENA_SIZE);
    errdefer allocator.free(gpa_arena);
    for (0..GPA_ARENA_SIZE) |i| {
        gpa_arena[i] = SafeGPA{
            .backing_allocator = if (util.IS_TEST) std.testing.allocator else std.heap.page_allocator,
        };
    }

    return Constellation{
        .allocator = allocator,
        .gpa_arena = gpa_arena.ptr,
        .bundles = .{},
    };
}

pub fn allocatorFor(self: *Constellation, id: SourceBundle.Id) Allocator {
    return self.gpa_arena[id.int() % GPA_ARENA_SIZE].allocator();
}
inline fn nextId(self: *Constellation) SourceBundle.Id {
    const id = self.next_id.fetchAdd(1, .monotonic);
    return SourceBundle.Id.tryFrom(id) orelse unreachable;
}

pub fn addFile(self: *Constellation, file: std.fs.File, pathname: ?[]const u8) Allocator.Error!SourceBundle {
    defer file.close();
    const id = self.nextId();
    const arena = ArenaAllocator.init(self.allocatorFor(id));
    errdefer arena.deinit();

    const meta = try file.metadata();
    const contents = try arena.allocSentinel(u8, meta.size(), 0);
    const bytes_read = try file.readAll(contents);
    assert(bytes_read == meta.size());
    // const contents = try std.zig.readSourceFileToEndAlloc(gpa, file, meta.size());
    const bundle = SourceBundle{
        .arena = arena,
        .pathname = pathname,
        .ast = undefined, // todo
        // .contents = try ArcStr.init(gpa, contents),
        // .pathname = pathname,
        // .gpa = gpa,
    };
    _ = bundle;
}

pub fn deinit(self: *Constellation) void {
    var it = self.bundles.iterator();
    while (it.next()) |bundle| bundle.deinit();
    self.bundles.deinit(self.allocator);

    const gpas = self.gpa_arena[0..GPA_ARENA_SIZE];
    for (gpas) |*gpa| {
        _ = gpa.deinit();
    }
    self.allocator.free(gpas);

    self.* = undefined;
}

const SourceBundle = struct {
    arena: ArenaAllocator,
    // stage 1
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    pathname: ?[]const u8 = null,
    ast: Ast,

    pub const Id = util.NominalId(u32).Optional;

    pub fn deinit(self: *SourceBundle) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const std = @import("std");
const util = @import("util");
const atomic = std.atomic;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const Ast = std.zig.Ast;

const assert = std.debug.assert;
