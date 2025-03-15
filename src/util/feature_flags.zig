const FeatureFlags = @This();


/// Enable cross-file semantic analysis
pub const cross_file = true;

/// Type for container fields that only get populated when a feature flag is
/// enabled.
/// 
/// `feature_flag` is an enum variant for a comptime-known feature flag. When
/// disabled, this returns `void` so that values with this type get stripped at
/// compile time.
pub fn IfEnabled(T: type, comptime feature_flag: anytype) type {
    const flag: bool = @field(FeatureFlags, @tagName(feature_flag));
    return if (flag) T;
}

const Type = @import("std").builtin.Type;
