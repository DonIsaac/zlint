// todo: re-parse from user-friendly "rules" object into this Array-of-Structs (AoS).
rules: []RuleFilter,

/// Read and parse a config JSON file.
///
/// Path is relative to the current working directory. Caller is responsible
/// for freeing the returned config.
pub fn readFromFile(alloc: Allocator, path: string) !Parsed(Config) {
    const MAX_BYTES: usize = std.math.maxInt(u32);
    const contents = fs.cwd().readFileAlloc(alloc, path, MAX_BYTES) catch |err| {
        return err;
    };
    defer alloc.free(contents);

    return parse(alloc, contents);
}

/// Parse a config object from a JSON string.
///
/// String contents are borrowed. Caller is responsible for freeing the returned config.
pub fn parse(alloc: Allocator, contents: string) !Parsed(Config) {
    const config = std.json.parseFromSlice(Config, alloc, contents) catch |err| {
        return err;
    };

    return config;
}

/// A configured rule.
///
/// Stored in `"rules"` config field. Looks something like this:
/// ```json
/// {
///   // ...
///   "rules": {
///     "no-undefined": "error",
///   }
/// ```
const RuleFilter = struct {
    /// The name of the rule being configured.
    name: string,
    severity: Severity,
};

const Config = @This();

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Parsed = std.json.Parsed;

const Severity = @import("Error.zig").Severity;
const string = @import("util").string;
