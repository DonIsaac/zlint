import { type } from 'arktype'
import { Rule } from '@site/src/types'
import styles from './RuleBanner.module.css'
import Badge from './Badge'
import { Variant } from '../theme/types'
import clsx from 'clsx'
import Alert from './Alert'
import { WrenchIcon } from 'lucide-react'
import { capitalize, withAOrAn } from '../utils'

const Props = type({
  category: Rule.Category,
  fix: Rule.FixMeta.optional(),
  default: Rule.Severity,
})
type Props = typeof Props.inferIn

export default function RuleBanner(props: Props) {
  const { category, fix, default: defaultSeverity } = Props.assert(props)

  return (
    <div className={clsx('container', styles.ruleBanner)}>
      <div className="row">
        <Badge variant={categoryVariant(category)}>{capitalize(category)}</Badge>
      </div>
      <div className="row" style={{ gap: 'var(--ifm-spacing-horizontal)' }}>
        <SeverityBanner severity={defaultSeverity} />
        <FixBanner fix={fix} />
      </div>
    </div>
  )
}

const SeverityBanner = ({ severity }: { severity: Rule.Severity | null | undefined }) => {
  if (!severity || severity === 'off') return null
  let severityText: string | undefined
  switch (severity) {
    case 'err':
      severityText = 'an error'
      break
    case 'warning':
      severityText = 'a warning'
      break
    case 'notice':
      severityText = 'a notice'
      break
  }
  const variant = (
    {
      err: 'danger',
      warning: 'warning',
      notice: 'info',
    } as const
  )[severity]
  return (
    <Alert variant={variant} className="col--6">
      This rule is enabled as {severityText} by default.
    </Alert>
  )
}

const FixBanner = ({ fix }: { fix: Rule.FixMeta | null | undefined }) => {
  let fixText: string | undefined
  if (!fix || fix.kind === 'none') return null
  switch (fix.kind) {
    case 'fix':
      fixText = fix.dangerous ? 'dangerous fix' : 'auto-fix'
      break
    case 'suggestion':
      fixText = fix.dangerous ? 'dangerous suggestion' : 'suggestion'
  }
  return (
    <Alert variant={fix.dangerous ? 'danger' : 'info'} className="col--6">
      <WrenchIcon /> This rule has {withAOrAn(fixText)} available
    </Alert>
  )
}

const categoryVariants: Partial<Record<Rule.Category, Variant>> = {
  nursery: 'danger',
}
const categoryVariant = (category: Rule.Category) => categoryVariants[category] ?? 'info'
