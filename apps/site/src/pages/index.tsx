import type { ReactNode } from 'react'
import clsx from 'clsx'
import useDocusaurusContext from '@docusaurus/useDocusaurusContext'
import Layout from '@theme/Layout'
import HomepageFeatures from '@site/src/components/HomepageFeatures'
import Heading from '@theme/Heading'

import styles from './index.module.css'
import { GithubIcon, BookOpenIcon  } from 'lucide-react'
import Button from '../components/Button'

function HomepageHeader() {
    const { siteConfig } = useDocusaurusContext()
    return (
        <header className={clsx('hero hero--dark', styles.heroBanner)}>
            <div className="container">
                <Heading as="h1" className="hero__title">
                    <span className="font-abyssinica text--primary">Z</span>
                    <span className="text--black">Lint</span>
                </Heading>
                <p className="hero__subtitle">{siteConfig.tagline}</p>
                <Button.Row>
                    <Button href="/docs/installation" variant="secondary">
                        <BookOpenIcon /> Get Started
                    </Button>
                    <Button
                        href={
                            (siteConfig.customFields as {
                                social: { github: string }
                            })!.social.github
                        }
                        target="_blank"
                    >
                        <GithubIcon /> GitHub
                    </Button>
                </Button.Row>
            </div>
        </header>
    )
}

export default function Home(): ReactNode {
    const { siteConfig } = useDocusaurusContext()
    return (
        <Layout
            title={siteConfig.title}
            description={siteConfig.tagline}
        >
            <HomepageHeader />
            <main>
                <HomepageFeatures />
            </main>
        </Layout>
    )
}
