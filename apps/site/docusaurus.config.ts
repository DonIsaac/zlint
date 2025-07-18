import { themes as prismThemes } from 'prism-react-renderer'
import type { Config, PluginModule } from '@docusaurus/types'
import type * as Preset from '@docusaurus/preset-classic'
import path from 'path'
import fs from 'fs/promises'
import assert from 'assert'

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const rulesPlugin: PluginModule<Record<string, { meta: any, tldr: string }>> = (ctx, options) => {
  return {
    name: 'zlint-rules-plugin',
    async loadContent() {
      const dir = path.resolve('docs/rules')
      const ruleDocPaths: string[] = await fs
        .readdir(dir)
        .then((rules) =>
          rules.filter((r) => r.endsWith('.mdx') && !r.startsWith('index')).map((r) => path.join(dir, r))
        )
      const ruleDocs: string[] = await Promise.all(ruleDocPaths.map((r) => fs.readFile(r, 'utf8')))
      let ruleMetas: Record<string, any> = {}
      for (const rule of ruleDocs) {
        let start = rule.indexOf("rule: ");
        assert(start >= 0);
        while (rule.charAt(start) != '{') start++;
        let end = rule.indexOf('\n', start);
        while(["'", " "].includes(rule.charAt(end))) end--;
        end -= 1;
        assert(end > start);
        const meta = JSON.parse(rule.slice(start, end));

        const ruleDocsStartMarker = 'What This Rule Does'
        let ruleDocsStart = rule.indexOf(ruleDocsStartMarker)
        assert(ruleDocsStart >= 0);
        ruleDocsStart += ruleDocsStartMarker.length;
        const tldr = rule.slice(ruleDocsStart).trimStart().split('\n').at(0);

        ruleMetas[meta.name] = { meta, tldr }


      }
      return ruleMetas
    },
    async contentLoaded({ content, actions }) {
      actions.setGlobalData({ rules: content })
      
    },
  }
}

const config: Config = {
  title: 'ZLint',
  tagline: 'An opinionated linter for the Zig programming language',
  favicon: 'img/favicon.ico',

  // Future flags, see https://docusaurus.io/docs/api/docusaurus-config#future
  future: {
    v4: true, // Improve compatibility with the upcoming Docusaurus v4
  },

  // Set the production url of your site here
  url: 'https://donisaac.github.io',
  // Set the /<baseUrl>/ pathname under which your site is served
  // For GitHub pages deployment, it is often '/<projectName>/'
  baseUrl: '/zlint/',

  // GitHub pages deployment config.
  // If you aren't using GitHub pages, you don't need these.
  organizationName: 'DonIsaac', // Usually your GitHub org/user name.
  projectName: 'zlint', // Usually your repo name.
  deploymentBranch: 'gh-pages',

  onBrokenLinks: 'throw',
  onBrokenMarkdownLinks: 'warn',
  trailingSlash: false,

  // Even if you don't use internationalization, you can use this field to set
  // useful metadata like html lang. For example, if your site is Chinese, you
  // may want to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },
  customFields: {
    social: {
      github: 'https://github.com/DonIsaac/zlint',
    },
  },
  plugins: [rulesPlugin as PluginModule<any>],

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          // Please change this to your repo.
          // Remove this to remove the "edit this page" links.
          editUrl: 'https://github.com/DonIsaac/zlint/tree/main/apps/site',
        },
        blog: {
          showReadingTime: true,
          feedOptions: {
            type: ['rss', 'atom'],
            xslt: true,
          },
          // Please change this to your repo.
          // Remove this to remove the "edit this page" links.
          editUrl: 'https://github.com/DonIsaac/zlint/tree/main/apps/site',
          // Useful options to enforce blogging best practices
          onInlineTags: 'warn',
          onInlineAuthors: 'warn',
          onUntruncatedBlogPosts: 'warn',
        },
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    // Replace with your project's social card
    // image: 'img/docusaurus-social-card.jpg',
    docs: {
      sidebar: {
        autoCollapseCategories: true,
      },
    },
    colorMode: {
      respectPrefersColorScheme: true,
      defaultMode: 'dark',
    },
    navbar: {
      title: 'ZLint',
      logo: {
        alt: 'ZLint Logo',
        src: 'img/logo.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docs',
          position: 'left',
          label: 'Docs',
        },
        { to: '/blog', label: 'Blog', position: 'left' },
        { to: 'pathname:///lib-docs/index.html', label: 'Zig Docs', position: 'left' },
        {
          href: 'https://github.com/DonIsaac/zlint',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {
              label: 'Rules',
              to: '/docs/category/rules',
            },
          ],
        },
        {
          title: 'Community',
          items: [
            // {
            //   label: 'Stack Overflow',
            //   href: 'https://stackoverflow.com/questions/tagged/docusaurus',
            // },
            {
              label: 'Discord',
              href: 'https://discord.gg/UcB7HjJxcG',
            },
            // {
            //   label: 'X',
            //   href: 'https://x.com/docusaurus',
            // },
          ],
        },
        {
          title: 'More',
          items: [
            {
              label: 'Blog',
              to: '/blog',
            },
            {
              label: 'GitHub',
              href: 'https://github.com/DonIsaac/zlint',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Don Isaac.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['zig'],
      magicComments: [
        {
          className: 'theme-code-block-highlighted-line',
          line: 'highlight-next-line',
          block: { start: 'highlight-start', end: 'highlight-end' },
        },
      ],
    },
  } satisfies Preset.ThemeConfig,
}

export default config
