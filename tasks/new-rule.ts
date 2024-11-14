#!/usr/bin/env bun

import path from 'path'
import fs from 'fs'

const RULES_DIR = 'src/linter/rules'

function main(argv: string[]) {
    let ruleName = argv[2]
    // lower-kebab-case
    ruleName = ruleName.replaceAll(' ', '-').replaceAll('_', '-').toLowerCase()

    // snake_case filenames
    const filename = `${ruleName.replaceAll('-', '_')}.zig`
    const rulepath = path.resolve(__dirname, '..', RULES_DIR, filename)
    if (fs.existsSync(rulepath)) {
        throw new Error(`Rule ${ruleName} already exists`)
    }
    fs.writeFileSync(rulepath, createRule({ name: ruleName }))
}

const createRule = ({ name }) => {
    const StructName = kebabToPascal(name)
    const underscored = name.replaceAll('-', '_');
    return /* zig */ `
const std = @import("std");
const _source = @import("../../source.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Loc = std.zig.Loc;
const Span = _source.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = @import("../rule.zig").Rule;
const NodeWrapper = @import("../rule.zig").NodeWrapper;

pub const ${StructName} = struct {
    pub const Name = "${name}";

    pub fn runOnNode(_: *const ${StructName}, wrapper: NodeWrapper, ctx: *LinterContext) void {
        _ = wrapper;
        _ = ctx;
        @panic("TODO: implement this rule");
    }

    pub fn rule(self: *${StructName}) Rule {
        return Rule.init(self);
    }
};

const RuleTester = @import("../tester.zig");
test ${StructName} {
    const t = std.testing;

    var ${underscored} = ${StructName}{};
    var runner = RuleTester.init(t.allocator, ${underscored}.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1";
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1";
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
`
}

const kebabToPascal = (kebab: string) =>
    kebab.split('-').map(capitalize).join('')
const capitalize = (word: string) => word[0].toUpperCase() + word.slice(1)

if (require.main === module) {
    main(process.argv)
}
