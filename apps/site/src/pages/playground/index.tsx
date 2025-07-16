import Editor from '@monaco-editor/react'
import Layout from '@theme/Layout'

import styles from './playground.module.css'
import useDocusaurusContext from '@docusaurus/useDocusaurusContext'
// https://infima.dev/docs/layout/grid
export default function Playground() {
  const { siteConfig } = useDocusaurusContext()
  const light =
    (siteConfig.themeConfig.colorMode as { defaultMode: 'dark' | 'light' } | undefined)?.defaultMode === 'light'
  return (
    <Layout title="Playground" wrapperClassName="full container">
      <div className="row row--no-gutters">
        <div className="col col--6">
          <Editor language="zig" theme={light ? 'light' : 'vs-dark'} className={styles.editor} />
        </div>
        <div className="col col--4">aspdoifhdsap</div>
      </div>
    </Layout>
  )
}
