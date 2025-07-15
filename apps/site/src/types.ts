import { type } from 'arktype'

export namespace Rule {
  export const Severity = type("'off' | 'warning' | 'err' | 'notice'")
  export type Severity = typeof Severity.infer

  /** `FixMeta` in `src/linter/fix.zig` */
  export const FixMeta = type({
    kind: '"fix" | "suggestion" | "none"',
    dangerous: 'boolean',
  })
  export type FixMeta = typeof FixMeta.infer

  export const Category = type(
    "'compiler' | 'correctness' | 'suspicious' | 'restriction' | 'pedantic' | 'style' | 'nursery'"
  )
  export type Category = typeof Category.infer
}
