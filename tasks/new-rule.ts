#!/usr/bin/env bun

import path from 'path'
import fs from 'fs'
import assert from 'assert'

const RULES_DIR = 'src/linter/rules'
const RULES_MODULE = 'src/linter/rules.zig'
const CONFIG_PATH = 'src/linter/config/rules_config.zig'
const p = (...segs: string[]) => path.join(__dirname, '..', ...segs)

class RuleData {
    /** rule-name */
    name: string
    /** rule_name */
    underscored: string
    /** RuleName */
    StructName: string

    constructor(name: string) {
        this.name = name.replaceAll(' ', '-').replaceAll('_', '-').toLowerCase()
        this.StructName = kebabToPascal(this.name)
        this.underscored = this.name.replaceAll('-', '_')
    }

    get path(): string {
        return p(RULES_DIR, this.filename)
    }

    get filename(): string {
        return `${this.underscored}.zig`
    }
}

async function main(argv: string[]) {
    let ruleName = argv[2]
    // lower-kebab-case
    const rule = new RuleData(ruleName)

    // const rulepath = p(RULES_DIR, filename)
    if (fs.existsSync(rule.path)) {
        throw new Error(`Rule ${ruleName} already exists`)
    }
    const reExport = `pub const ${rule.StructName} = @import("./rules/${rule.filename}");`
    await Promise.all([
        fs.promises.writeFile(rule.path, createRule(rule)),
        fs.promises.appendFile(p(RULES_MODULE), reExport),
        updateConfig(rule),
    ])
}


/**
 * Insert a `RuleConfig` field into `RulesConfig` for the new rule.
 * 
 * ```zig
 *    // ...
 *    rule_name: RuleConfig(rules.RuleName) = .{},
 *    // ...
 * ```
 */
const updateConfig = async (rule: RuleData) => {
    let ruleConfig = await fs.promises.readFile(p(CONFIG_PATH), 'utf-8');
    const pattern = "pub const RulesConfig = struct {"
    let insertAt = ruleConfig.indexOf(pattern)
    assert(insertAt > 0)
    insertAt += pattern.length
    do {
        insertAt++
    } while (ruleConfig[insertAt] !== '\n')
    ruleConfig = ruleConfig.slice(0, insertAt) +
        `    ${rule.underscored}: RuleConfig(rules.${rule.StructName}) = .{},` +
        ruleConfig.slice(insertAt)

    await fs.promises.writeFile(p(CONFIG_PATH), ruleConfig)
}

const createRule = ({ name, StructName, underscored }: RuleData) => {
    return /* zig */ `
//! ## What This Rule Does
//! Explain what this rule checks for. Also explain why this is a problem.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! \`\`\`zig
//! \`\`\`
//!
//! Examples of **correct** code for this rule:
//! \`\`\`zig
//! \`\`\`

const std = @import("std");
const util = @import("util");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Loc = std.zig.Loc;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const ${StructName} = @This();
pub const meta: Rule.Meta = .{
    .name = "${name}",
    // TODO: set the category to an appropriate value
    .category = .correctness,
};

// Runs once per source file. Useful for unique checks
pub fn runOnce(_: *const ${StructName}, ctx: *LinterContext) void {
    _ = wrapper;
    _ = ctx;
    @panic("TODO: implement runOnce, or remove it if not needed");
}

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
        "const x = 1;",
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1;",
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
