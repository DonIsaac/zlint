//! GitHub release metadata parsing and target selection.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const maximum_asset_size = 128 * 1024 * 1024;

pub const Digest = [Sha256.digest_length]u8;

pub const Metadata = struct {
    tag_name: []const u8,
    assets: []const Asset,

    /// Parses only the GitHub fields the updater consumes.
    pub fn parseFromSlice(alloc: Allocator, json: []const u8) !std.json.Parsed(Metadata) {
        return std.json.parseFromSlice(Metadata, alloc, json, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
    }

    /// Selects an asset and validates its size, URL, and digest.
    pub fn selectAsset(metadata: Metadata, name: []const u8) !Asset.Validated {
        const asset = findAsset(metadata.assets, name) orelse return error.ReleaseAssetNotFound;
        if (asset.size == 0 or asset.size > maximum_asset_size) return error.ReleaseAssetTooLarge;
        if (!isHttps(asset.browser_download_url)) return error.InsecureDownloadUrl;

        return .{
            .download_url = asset.browser_download_url,
            .size = asset.size,
            .digest = try parseDigest(asset.digest orelse return error.ReleaseAssetMissingDigest),
        };
    }
};

pub const Asset = struct {
    name: []const u8,
    browser_download_url: []const u8,
    digest: ?[]const u8 = null,
    size: u64,
    const Validated = struct {
        download_url: []const u8,
        size: u64,
        digest: Digest,
    };
};

/// Accepts release versions with or without the conventional leading `v`.
pub fn parseVersion(version: []const u8) !std.SemanticVersion {
    const normalized = if (std.mem.startsWith(u8, version, "v")) version[1..] else version;
    return std.SemanticVersion.parse(normalized);
}

pub fn assetNameForTarget(comptime os: std.Target.Os.Tag, comptime arch: std.Target.Cpu.Arch) ?[]const u8 {
    if (!isPublishedTarget(os, arch)) return null;

    const extension = if (os == .windows) ".exe" else "";
    return "zlint-" ++ @tagName(os) ++ "-" ++ @tagName(arch) ++ extension;
}

pub fn verifyDigest(actual: Digest, expected: Digest) !void {
    if (!std.crypto.timing_safe.eql(Digest, actual, expected)) return error.ChecksumMismatch;
}

fn findAsset(assets: []const Asset, name: []const u8) ?Asset {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) return asset;
    }
    return null;
}

fn isPublishedTarget(comptime os: std.Target.Os.Tag, comptime arch: std.Target.Cpu.Arch) bool {
    return switch (os) {
        .macos, .windows => arch == .aarch64 or arch == .x86_64,
        .linux => arch == .aarch64 or
            arch == .x86_64 or
            arch == .riscv64 or
            arch == .loongarch64,
        else => false,
    };
}

fn parseDigest(digest: []const u8) !Digest {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, digest, prefix)) return error.InvalidDigest;

    const encoded = digest[prefix.len..];
    if (encoded.len != Sha256.digest_length * 2) return error.InvalidDigest;

    // SAFETY: `encoded` is exactly twice the digest length, so a successful
    // `hexToBytes` writes every byte.
    var result: Digest = undefined;
    _ = std.fmt.hexToBytes(&result, encoded) catch return error.InvalidDigest;
    return result;
}

fn isHttps(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "https");
}

const t = std.testing;

test "semantic versions are normalized and ordered" {
    try t.expectEqual(.eq, (try parseVersion("v1.2.3")).order(try parseVersion("1.2.3")));
    try t.expectEqual(.lt, (try parseVersion("v0.0.0")).order(try parseVersion("v0.9.1")));
    try t.expectEqual(.gt, (try parseVersion("v1.0.0")).order(try parseVersion("v0.9.1")));
    try t.expectEqual(.lt, (try parseVersion("v1.0.0-rc.1")).order(try parseVersion("v1.0.0")));
    try t.expectError(error.InvalidVersion, parseVersion("not-a-version"));
}

test "asset names cover every published target" {
    const cases = [_]struct { std.Target.Os.Tag, std.Target.Cpu.Arch, []const u8 }{
        .{ .macos, .aarch64, "zlint-macos-aarch64" },
        .{ .macos, .x86_64, "zlint-macos-x86_64" },
        .{ .linux, .aarch64, "zlint-linux-aarch64" },
        .{ .linux, .x86_64, "zlint-linux-x86_64" },
        .{ .linux, .riscv64, "zlint-linux-riscv64" },
        .{ .linux, .loongarch64, "zlint-linux-loongarch64" },
        .{ .windows, .aarch64, "zlint-windows-aarch64.exe" },
        .{ .windows, .x86_64, "zlint-windows-x86_64.exe" },
    };
    inline for (cases) |case| try t.expectEqualStrings(case[2], assetNameForTarget(case[0], case[1]).?);

    try t.expect(assetNameForTarget(.macos, .riscv64) == null);
    try t.expect(assetNameForTarget(.freebsd, .x86_64) == null);
}

test "metadata parsing ignores fields added by GitHub" {
    const json =
        \\{
        \\  "tag_name": "v1.2.3",
        \\  "ignored": true,
        \\  "assets": [{
        \\    "name": "zlint-linux-x86_64",
        \\    "browser_download_url": "https://example.com/zlint",
        \\    "digest": "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        \\    "size": 3,
        \\    "ignored": "value"
        \\  }]
        \\}
    ;
    var parsed = try Metadata.parseFromSlice(t.allocator, json);
    defer parsed.deinit();

    try t.expectEqualStrings("v1.2.3", parsed.value.tag_name);
    const asset = try parsed.value.selectAsset("zlint-linux-x86_64");
    try t.expectEqual(@as(u64, 3), asset.size);
}

test "malformed metadata is rejected" {
    try t.expectError(error.UnexpectedEndOfInput, Metadata.parseFromSlice(t.allocator, "{"));
}

test "asset selection validates release metadata" {
    const digest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const valid = Asset{
        .name = "zlint-linux-x86_64",
        .browser_download_url = "https://example.com/zlint",
        .digest = digest,
        .size = 3,
    };
    const metadata = Metadata{ .tag_name = "v1.0.0", .assets = &.{valid} };

    _ = try metadata.selectAsset(valid.name);
    try t.expectError(error.ReleaseAssetNotFound, metadata.selectAsset("zlint-linux-aarch64"));

    var invalid = valid;
    invalid.size = 0;
    try expectInvalidAsset(error.ReleaseAssetTooLarge, invalid);
    invalid.size = maximum_asset_size + 1;
    try expectInvalidAsset(error.ReleaseAssetTooLarge, invalid);

    invalid = valid;
    invalid.browser_download_url = "http://example.com/zlint";
    try expectInvalidAsset(error.InsecureDownloadUrl, invalid);

    invalid = valid;
    invalid.digest = null;
    try expectInvalidAsset(error.ReleaseAssetMissingDigest, invalid);
    invalid.digest = "sha256:invalid";
    try expectInvalidAsset(error.InvalidDigest, invalid);
}

test "SHA-256 digests require GitHub's exact encoding" {
    const encoded = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    var expected: Digest = undefined;
    Sha256.hash("abc", &expected, .{});

    try t.expectEqual(expected, try parseDigest("sha256:" ++ encoded));
    try t.expectError(error.InvalidDigest, parseDigest(encoded));
    try t.expectError(error.InvalidDigest, parseDigest("sha256:abcd"));
    try t.expectError(error.InvalidDigest, parseDigest("sha256:" ++ ("z" ** 64)));
}

test "digest verification rejects mismatches" {
    var actual: Digest = undefined;
    var expected: Digest = undefined;
    Sha256.hash("actual", &actual, .{});
    Sha256.hash("expected", &expected, .{});

    try t.expectError(error.ChecksumMismatch, verifyDigest(actual, expected));
}

fn expectInvalidAsset(expected_error: anyerror, asset: Asset) !void {
    const metadata = Metadata{ .tag_name = "v1.0.0", .assets = &.{asset} };
    try t.expectError(expected_error, metadata.selectAsset(asset.name));
}
