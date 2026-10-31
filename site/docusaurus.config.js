// @ts-check

const REPO = "https://github.com/NggKhaiz/ZMRIG";
const SITE = "https://nggkhaiz.github.io";
const BASE = "/ZMRIG/";
const VERSION = require("./package.json").version;

// Algolia DocSearch is the search of record for this site. The keys are issued
// per site by Algolia when an application is accepted (see doc/DOCS-SITE.md).
// They are not secrets, but they are not guessable either, so they come from
// the environment; until they exist, the local index below covers the gap.
//
//   ALGOLIA_APP_ID      e.g. ABC123XYZ
//   ALGOLIA_API_KEY     the search-only key, safe to ship
//   ALGOLIA_INDEX_NAME  e.g. zmrig
function algoliaConfig() {
  const appId = process.env.ALGOLIA_APP_ID;
  const apiKey = process.env.ALGOLIA_API_KEY;
  const indexName = process.env.ALGOLIA_INDEX_NAME;
  if (!appId || !apiKey || !indexName) return null;
  return { appId, apiKey, indexName, contextualSearch: true, insights: false };
}

const algolia = algoliaConfig();

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "ZMRIG",
  tagline: "RandomX miner, 0 % developer fee, made by @nggkhaiz",
  favicon: "img/z.svg",

  url: SITE,
  baseUrl: BASE,
  trailingSlash: false,

  organizationName: "NggKhaiz",
  projectName: "ZMRIG",

  onBrokenLinks: "throw",

  // English is the default; Vietnamese is a full translation, not a subset.
  i18n: {
    defaultLocale: "en",
    locales: ["en", "vi"],
    localeConfigs: {
      en: { label: "English", direction: "ltr", htmlLang: "en" },
      vi: { label: "Tiếng Việt", direction: "ltr", htmlLang: "vi" },
    },
  },

  markdown: {
    hooks: { onBrokenMarkdownLinks: "throw" },
  },

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: require.resolve("./sidebars.js"),
          routeBasePath: "docs",
          editUrl: `${REPO}/edit/BETA/site/`,
          breadcrumbs: true,
        },
        blog: false,
        theme: {
          customCss: require.resolve("./src/css/custom.css"),
        },
        sitemap: {
          changefreq: "weekly",
          priority: 0.7,
        },
      }),
    ],
  ],

  themes: [
    // Only when DocSearch keys are absent: the navbar renders one search box,
    // never two. Algolia is the long-term home of search for this site.
    ...(algolia
      ? []
      : [
          [
            require.resolve("@easyops-cn/docusaurus-search-local"),
            {
              hashed: true,
              language: ["en"],
              indexDocs: true,
              indexBlog: false,
              indexPages: true,
              docsRouteBasePath: "/docs",
              highlightSearchTermsOnTargetPage: true,
              searchResultLimits: 8,
            },
          ],
        ]),
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      metadata: [
        { name: "author", content: "@nggkhaiz" },
        { property: "og:site_name", content: "ZMRIG" },
        { name: "twitter:card", content: "summary" },
      ],
      colorMode: {
        defaultMode: "light",
        disableSwitch: false,
        respectPrefersColorScheme: true,
      },
      algolia: algolia ?? undefined,
      navbar: {
        title: "ZMRIG",
        logo: { alt: "ZMRIG", src: "img/z.svg", srcDark: "img/z.svg" },
        items: [
          {
            type: "docSidebar",
            sidebarId: "docs",
            position: "left",
            label: "Documentation",
          },
          { to: "/docs/install/quickstart", position: "left", label: "Install" },
          { to: "/docs/economics/profitability", position: "left", label: "Calculator" },
          { to: "/docs/reference/benchmarks", position: "left", label: "Benchmarks" },
          { type: "localeDropdown", position: "right" },
          {
            href: REPO,
            position: "right",
            className: "header-github-link",
            "aria-label": "GitHub repository",
          },
        ],
      },
      footer: {
        style: "dark",
        links: [
          {
            title: "Documentation",
            items: [
              { label: "What ZMRIG is", to: "/docs/intro" },
              { label: "Install", to: "/docs/install/quickstart" },
              { label: "Configuration", to: "/docs/configure/config-file" },
              { label: "Command reference", to: "/docs/configure/cli" },
            ],
          },
          {
            title: "Operations",
            items: [
              { label: "Pools", to: "/docs/pools/choosing" },
              { label: "Networks that only allow 443", to: "/docs/operate/networks" },
              { label: "Performance", to: "/docs/operate/performance" },
              { label: "Troubleshooting", to: "/docs/operate/troubleshooting" },
            ],
          },
          {
            title: "Project",
            items: [
              { label: "Profitability calculator", to: "/docs/economics/profitability" },
              { label: "Farm proxy", to: "/docs/fleet/proxy" },
              { label: "Self-hosted pool", to: "/docs/fleet/pool" },
              { label: "Testing", to: "/docs/development/testing" },
              { label: "Source", href: REPO },
              { label: "Issues", href: `${REPO}/issues` },
            ],
          },
        ],
        copyright: `ZMRIG ${VERSION} · GPL-3.0 · made by <a href="https://github.com/NggKhaiz">@nggkhaiz</a> · no tracking, no accounts, no developer fee`,
      },
      docs: {
        sidebar: {
          hideable: true,
          autoCollapseCategories: true,
        },
      },
      prism: {
        additionalLanguages: ["bash", "json", "ini", "diff"],
        defaultLanguage: "bash",
      },
      tableOfContents: {
        minHeadingLevel: 2,
        maxHeadingLevel: 3,
      },
    }),
};

module.exports = config;
