const reporter = @import("./reporter/Reporter.zig");
pub const Reporter = reporter.Reporter;
pub const _Reporter = reporter._Reporter;
pub const Options = reporter.Options;

pub const formatter = @import("./reporter/formatter.zig");

// shorthands
pub const GraphicalReporter = Reporter(formatter.Graphical, formatter.Graphical.format);
pub const GithubReporter = Reporter(formatter.Github, formatter.Github.format);

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Error = @import("Error.zig");
const Span = @import("span.zig").Span;
const Mutex = std.Thread.Mutex;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?
