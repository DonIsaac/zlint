const IS_DEBUG = @import("../util.zig").IS_DEBUG;

/// Wraps a type so that it is eliminated in release builds. Useful for
/// eliminating container members that are used only for debug checks.
///
/// ## Example
/// ```zig
/// const Foo = struct {
///   debug_check: DebugOnly(u32) = debugOnly(u32, 42),
/// };
/// ```
pub fn DebugOnly(comptime T: type) type {
    return comptime if (IS_DEBUG) T else void;
}

/// Eliminates a value in release builds. In debug builds, this is an identity
/// function.
///
/// ## Example
/// ```zig
/// const Foo = struct {
///   debug_check: DebugOnly(u32) = debugOnly(u32, 42),
/// };
/// ```
pub inline fn debugOnly(T: type, value: T) DebugOnly(T) {
    return if (IS_DEBUG) value;
}
