import Editor from '@monaco-editor/react'
import Layout from '@theme/Layout'

import styles from './playground.module.css'
import useDocusaurusContext from '@docusaurus/useDocusaurusContext'
import { useEffect, useRef } from 'react'
// https://infima.dev/docs/layout/grid
export default function Playground() {
  const { siteConfig } = useDocusaurusContext()
  const light =
    (siteConfig.themeConfig.colorMode as { defaultMode: 'dark' | 'light' } | undefined)?.defaultMode === 'light'

  const worker = useRef<Worker>(undefined);
  const outputDiv = useRef<HTMLDivElement>(null);

  useEffect(() => {
    worker.current = new Worker("/zlint/js/worker.js");
    worker.current.onmessage = ({ data }) => {
      if (outputDiv.current === null) return;
      outputDiv.current.textContent = data.result
    };

    return () => worker.current?.terminate();
  }, []);

  return (
    <Layout title="Playground" wrapperClassName="full container">
      <div className="row row--no-gutters">
        <div className="col col--6">
          <Editor
            language="zig"
            theme={light ? 'light' : 'vs-dark'}
            className={styles.editor}
            onChange={(model) => {
              if (worker.current === undefined) return;
              worker.current.postMessage({ type: "analyze", zigCode: model })
            }}
          />
        </div>
        <div ref={outputDiv} className="col col--4">aspdoifhdsap</div>
      </div>
    </Layout>
  )
}
