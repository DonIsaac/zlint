#!/usr/bin/env bun

import path from 'path'
import fs from 'fs'

const RULES_DIR = 'src/linter/rules'
const RULES_MODULE = 'src/linter/rules.zig'
const p = (...segs: string[]) => path.join(__dirname, '..', ...segs)

async function main(argv: string[]) {
    let ruleName = argv[2]
    // lower-kebab-case
    ruleName = ruleName.replaceAll(' ', '-').replaceAll('_', '-').toLowerCase()
    const StructName = kebabToPascal(ruleName);

    // snake_case filenames
    const filename = `${ruleName.replaceAll('-', '_')}.zig`
    const rulepath = p(RULES_DIR, filename)
    if (fs.existsSync(rulepath)) {
        throw new Error(`Rule ${ruleName} already exists`)
    }
    const reExport = `pub const ${StructName} = @import("./rules/${filename}");`
    await Promise.all([
        fs.promises.writeFile(rulepath, createRule({ name: ruleName, StructName })),
        fs.promises.appendFile(p(RULES_MODULE), reExport)
    ])
}

const createRule = ({ name, StructName }) => {
    const underscored = name.replaceAll('-', '_');
    return /* zig */ `
const std = @import("std");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const rule = @import("../rule.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Loc = std.zig.Loc;
const Span = _source.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = rule.Rule;
const NodeWrapper = rule.NodeWrapper;

// Rule metadata
const ${StructName} = @This();
pub const Name = "${name}";

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const ${StructName}, wrapper: NodeWrapper, ctx: *LinterContext) void {
    _ = wrapper;
    _ = ctx;
    @panic("TODO: implement runOnNode, or remove it if not needed");
}

pub fn runOnSymbol(_: *const ${StructName}, symbol: Symbol.Id, ctx: *LinterContext) void {
    _ = symbol;
    _ = ctx;
    @panic("TODO: implement runOnSymbol, or remove it if not needed");
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *${StructName}) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test ${StructName} {
    const t = std.testing;

    var ${underscored} = ${StructName}{};
    var runner = RuleTester.init(t.allocator, ${underscored}.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1",
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}`.trim()
}

const kebabToPascal = (kebab: string) =>
    kebab.split('-').map(capitalize).join('')
const capitalize = (word: string) => word[0].toUpperCase() + word.slice(1)

if (require.main === module) {
    main(process.argv)
}
