import type { ReactNode } from 'react'
import clsx from 'clsx'
import Heading from '@theme/Heading'
import styles from './styles.module.css'
import Link from '@docusaurus/Link'

type FeatureItem = {
  title: string
  Svg?: React.ComponentType<React.ComponentProps<'svg'>>
  description: ReactNode
}

const FeatureList: FeatureItem[] = [
  {
    title: '🔍 Custom Analysis',
    // Svg: require('@site/static/img/undraw_docusaurus_mountain.svg').default,
    description: (
      <>
        ZLint's custom semantic analyzer, inspired by <Link to="https://github.com/oxc-project/oxc">Oxc</Link>, is
        completely separate from the Zig compiler. This means that
        <b>ZLint still checks and understands code that may otherwise be ignored by Zig due to dead code elimination</b>
      </>
    ),
  },
  {
    title: '⚡️ Fast',
    // Svg: require('@site/static/img/undraw_docusaurus_tree.svg').default,
    description: (
      <>
        Designed from the ground-up to be highly performant, ZLint runs in just a <b>few hundred milliseconds</b>.
      </>
    ),
  },
  {
    title: '💡 Understandable',
    // Svg: require('@site/static/img/undraw_docusaurus_react.svg').default,
    description: (
      <>
        Error messages are pretty, detailed, and easy to understand. Most rules come with explanations on how to fix
        them and what <i>exactly</i> is wrong.
      </>
    ),
  },
]

function Feature({ title, Svg, description }: FeatureItem) {
  return (
    <div className={clsx('col col--4')}>
      <div className="text--center">{Svg && <Svg className={styles.featureSvg} role="img" />}</div>
      <div className="text--center padding-horiz--md">
        <Heading as="h3">{title}</Heading>
        <p>{description}</p>
      </div>
    </div>
  )
}

export default function HomepageFeatures(): ReactNode {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  )
}
