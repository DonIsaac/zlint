const std = @import("std");
const rules = @import("rules.zig");
const Rule = @import("rule.zig").Rule;

pub const RuleEnum = union(enum) {
    homeless_try: rules.HomelessTry,
    no_catch_return: rules.NoCatchReturn,
    no_undefined: rules.NoUndefined,
    no_unresolved: rules.NoCatchReturn,

    pub fn rule(self: *RuleEnum) Rule {
        switch (self) {
            .homeless_try => self.homeless_try.rule(),
            .no_catch_return => self.no_catch_return.rule(),
            .no_undefined => self.no_undefined.rule(),
            .no_unresolved => self.no_unresolved.rule(),
        }
    }
};
