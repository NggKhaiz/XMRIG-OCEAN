# The documentation site

The site at <https://nggkhaiz.github.io/ZMRIG/docs/intro> is a Docusaurus 3
project in [`site/`](../site). It is two locales (English is the default,
Vietnamese is a full translation), one sidebar with a fixed order, and three
calculators that run in the browser.

This page covers what only a maintainer needs: how the site is published given
this repository's Pages configuration, how to turn on Algolia DocSearch, and
which files are generated and must not be edited by hand.

## Why the build output is committed

GitHub Pages for this repository is set to **Deploy from a branch → `BETA` →
`/`**, which means the branch root *is* the published site. That setting can be
changed only from the repository's settings page; a workflow token cannot do it
(the API returns `403` for both `build_type` and `source`).

So instead of an Actions artifact, the built site is copied into the repository
root by one script:

```bash
./scripts/publish-site.sh            # build in site/, then copy to the root
./scripts/publish-site.sh --check    # fail if the committed copy is stale
```

It replaces only the paths Docusaurus owns — `index.html`, `404.html`,
`search.html`, `search-index.json`, `sitemap.xml`, `assets/`, `docs/`, `vi/`,
`img/`. It never deletes `web/` (the previous static site), `robots.txt`,
`.nojekyll` or any file a human wrote.

`tests/docs/pages.sh` fails if the committed copy differs from `site/build`, so
a content change that was not published cannot be merged silently.

If Pages is ever moved to "Source: GitHub Actions", the committed copy becomes
redundant: point the workflow at `site/build` and delete the copied paths. The
`baseUrl` stays `/ZMRIG/` either way.

## Working on it

```bash
cd site
npm install          # once
npm start            # http://localhost:3000/ZMRIG/
npm run build        # both locales; throws on a broken link
npm test             # unit tests for the builders, calculators and i18n
```

`npm run build` is the real check: `onBrokenLinks` and
`onBrokenMarkdownLinks` are both `throw`, so a page that was renamed without
updating its links fails the build rather than shipping a 404.

### Layout

```text
site/
├── docusaurus.config.js    locales, baseUrl, navbar, footer, search
├── sidebars.js             one ordered sidebar; every page is listed by id
├── docs/                   English pages (the source of truth for facts)
├── i18n/vi/                Vietnamese pages + theme strings
├── src/lib/                pools, command builder, report codes, messages
├── src/components/         PoolTable, InstallBuilder, ProfitCalculator, CopyButton
├── src/theme/              ColorModeToggle: system / light / dark
├── src/pages/index.jsx     the home page
├── static/img/             logo and the donation QR
└── tests/                  command, report, pools, i18n
```

`src/lib/*.mjs` is deliberately free of React and of the DOM: the components
render it and `site/tests/*.test.mjs` calls it directly, so the page and the
tests cannot disagree about what a command or a payout means.

## Search: Algolia DocSearch

The site is built to use DocSearch and ships with a local index only as a
fallback for the period before the application is approved. Both produce exactly
one search box in the navbar — never two.

1. Apply at <https://docsearch.algolia.com/apply> with:
   - URL: `https://nggkhaiz.github.io/ZMRIG/`
   - email: the address you read
   - repository: `https://github.com/NggKhaiz/ZMRIG`
2. When the crawler is approved, Algolia issues three values: `appId`,
   `apiKey` (the **search-only** key) and `indexName`.
3. Put them in the build environment, not in the repository:

   ```bash
   cd site
   ALGOLIA_APP_ID=XXXXXXXXXX \
   ALGOLIA_API_KEY=0123456789abcdef0123456789abcdef \
   ALGOLIA_INDEX_NAME=zmrig \
   npm run build
   cd .. && ./scripts/publish-site.sh
   ```

   `scripts/publish-site.sh` runs `npm run build` itself, so export the three
   variables before calling it.
4. `docusaurus.config.js` attaches `themeConfig.algolia` only when all three
   exist; otherwise `@easyops-cn/docusaurus-search-local` builds the local index
   that is in `search-index.json` today.

The keys are public by design — a search-only key can only query. They are not
committed because every rebuild would otherwise ship a stale index name.

Search is a build-time feature: the crawler indexes the *published* pages, so it
will not see a page until that page has been published at least once.

## Language

English is the default and is served at `/ZMRIG/`; Vietnamese is served at
`/ZMRIG/vi/`. The switch is the `localeDropdown` in the navbar.

A page is translated by copying it to the same relative path under
`site/i18n/vi/docusaurus-plugin-content-docs/current/`. `site/tests/i18n.test.mjs`
checks that

- every English page has a Vietnamese counterpart and vice versa,
- each keeps its front matter, `slug` and component imports,
- the four theme JSON files are translated rather than left in English.

Adding a page therefore means two files plus one line in `sidebars.js`.

## Theme

`src/theme/ColorModeToggle/index.js` replaces Docusaurus' two-state switch with
three buttons — **Hệ thống / System**, **Sáng / Light**, **Tối / Dark** — because
a visitor who once picked "dark" could otherwise never return to following the
system. Docusaurus already stores `null` for that choice; the component exposes
it. `docusaurus.config.js` sets `defaultMode: "light"` and
`respectPrefersColorScheme: true`, so a first visit follows the operating system.

## Manual settings this repository still needs

These cannot be done by a token and are the only steps left for a maintainer:

| Setting | Where | Value |
| --- | --- | --- |
| Pages source | Settings → Pages | Deploy from a branch → `BETA` → `/` |
| Custom domain (optional) | Settings → Pages | add it, then change `url` in `site/docusaurus.config.js` and republish |
| DocSearch application | docsearch.algolia.com/apply | see above |
| Repository topics | Settings | `monero`, `miner`, `randomx`, `zig` |

Everything else — the build, the tests, the published files — runs from the
repository.
