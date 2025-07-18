import useGlobalData from '@docusaurus/useGlobalData'
import Badge from '@site/src/components/Badge'
import FlexRow from '@site/src/components/Row'
import { Rule } from '@site/src/types'
import { SearchIcon } from 'lucide-react'
import { FC, useDeferredValue, useMemo, useState } from 'react'
import styles from './RulesPage.module.css'
import clsx from 'clsx'
import { Variant } from '@site/src/theme/types'
import Link from '@docusaurus/Link'
type RuleMetadata = Record<string, { meta: Rule.Meta; tldr: string }>

export default function RulesPage() {
  const { rules, search, setSearch } = useRules()
  return (
    <div className={styles.page}>
      {/* Search Input */}
      <div className="margin-bottom--lg">
        <input
          type="text"
          placeholder="🔍 Search rules by name, category, or description..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className={styles.searchBar}
        />
      </div>

      {/* Rules Grid */}
      <div className={styles.rulesGrid}>
        {rules.map((r) => (
          <RuleCard key={r.name} {...r} />
        ))}
      </div>

      {/* No results message */}
      {rules.length === 0 && (
        <div className={styles.noSearchResults}>
          <p>
            <SearchIcon /> No rules found matching "{search}"
          </p>
        </div>
      )}
    </div>
  )
}

const RuleCard: FC<FinalRuleMeta> = ({ name, tldr, category, severity }) => {
  return (
    <Link to={`rules/${name}`} className={clsx('card', styles.ruleCard)}>
      <div className={clsx('card__header', styles.cardHeader)}>
        <h3>{name}</h3>
        <FlexRow>
          <Badge variant="info">{category}</Badge>
          {severity !== 'off' && <Badge variant={severityVariants[severity]}>{severity}</Badge>}
        </FlexRow>
      </div>
      <div className={clsx('card__body', styles.cardBody)}>
        <p>{tldr}</p>
      </div>
    </Link>
  )
}
const severityVariants: Record<Rule.Severity, Variant> = {
  off: 'secondary',
  notice: 'info',
  warning: 'warning',
  err: 'danger',
}

type FinalRuleMeta = Omit<Rule.Meta, 'default'> & {
  severity: Rule.Meta['default']
  tldr: string
}
function useRules() {
  const [search, setSearch] = useState('')
  const deferredSearch = useDeferredValue(search)
  const globalData = useGlobalData()

  const rules = (globalData['zlint-rules-plugin'].default as any).rules as RuleMetadata
  const allRules = useMemo(
    () =>
      Object.values(rules).map(({ meta: metaIn, tldr }) => {
        const { name, category, default: severity, fix } = Rule.Meta.assert(metaIn)
        return { name, category, severity, fix, tldr }
      }),
    [rules]
  )

  const filteredRules: FinalRuleMeta[] = useMemo(() => {
    const query = deferredSearch.toLowerCase()
    return allRules.filter((r) => {
      if (r.name.toLowerCase().includes(query.replaceAll(' ', '-'))) return true
      if (r.category.includes(query)) return true
      if (r.tldr.toLowerCase().includes(query)) return true
      return false
    })
  }, [allRules, deferredSearch])

  return {
    rules: filteredRules,
    search,
    setSearch,
  }
}
