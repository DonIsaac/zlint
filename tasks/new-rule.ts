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

test {
    std.testing.refAllDecls(@This());
}
`
}

const kebabToPascal = (kebab: string) =>
    kebab.split('-').map(capitalize).join('')
const capitalize = (word: string) => word[0].toUpperCase() + word.slice(1)

if (require.main === module) {
    main(process.argv)
}
