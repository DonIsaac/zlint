//! Feature flags guard work-in-progress features until they are ready to be
//! shipped.
//!
//! All flags are comptime-known. This may change in the future.

const config = @import("config");

/// Use Zig v0.15.x AST instead of v0.14.1 AST. Under development.
pub const experimental_15_ast: bool = config.experimental_15_ast;

/// Enable language server features.
///
/// Not yet implemented.
pub const lsp: bool = false;

/// Wraps `T` so that it becomes `void` if `feature_flag` is not enabled.
pub fn IfEnabled(feature_flag: anytype, T: type) type {
    const flag: bool = @field(@This(), @tagName(feature_flag));
    return if (flag) T else void;
}

/// Returns `value` if `feature_flag` is enabled, void otherwise.
pub fn ifEnabled(feature_flag: anytype, T: type, value: T) IfEnabled(feature_flag, T) {
    const flag: bool = @field(@This(), @tagName(feature_flag));
    if (flag) {
        return value;
    } else {
        return {};
    }
}
