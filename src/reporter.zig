const reporter = @import("./reporter/Reporter.zig");
pub const Reporter = reporter.Reporter;
pub const Options = reporter.Options;
pub const GraphicalFormatter = @import("./reporter/formatters/GraphicalFormatter.zig");

// shorthands
pub const GraphicalReporter = Reporter(GraphicalFormatter, GraphicalFormatter.format);

const IS_WINDOWS = builtin.target.os.tag == .windows;

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Error = @import("Error.zig");
const Span = @import("span.zig").Span;
const Mutex = std.Thread.Mutex;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?
