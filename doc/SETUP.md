# Setup: what still has to be done by hand

Everything in this repository works from a terminal. A handful of things do not:
they live in GitHub settings, in cloud dashboards that need an account of your
own, or they need a token scope this development environment does not have.
This page lists them, in the order worth doing, with the exact values to paste.

Each section says **why** it cannot be automated from here, and **how to check**
that it worked. If a step is already done, the check prints the expected value
and you move on.

| # | Task | Time | Needs |
|---|---|---|---|
| 1 | Branch layout and the open PR | 2 min | nothing — already done, verify only |
| 2 | Repository description, topics, homepage | 2 min | GitHub **Settings** access |
| 3 | CI for the site (`site.yml`) | 5 min | GitHub **Actions** write (token scope `workflows`) |
| 4 | Publish the documentation site | 10 min | GitHub Pages, or Cloudflare/Vercel account |
| 5 | Deploy the pool | 15 min | a `monerod` you control + Render/Fly account |
| 6 | Point one miner at it | 5 min | a Linux box with root |
| 7 | Optional: releases, custom domain, protection | 10 min | — |

---

## 1. Branch layout

Two branches are meant to live on: `BETA` (the default) and `master`. The one
other branch that exists today is a session artefact and can go:

| Branch | What it is | Rule |
|---|---|---|
| `BETA` | **default branch**, the release state | what people clone; what the installer and the site point at |
| `master` | the same release, keeping upstream history | target of the release PR; after the merge, `BETA` and `master` hold the same tree |
| `arena/918a7f95-xmrig-ocean` | head branch of the open PR | a session artefact — delete it once the PR is merged and the session is over |

The final state is two long-lived branches. `master` (upstream `6.26.0-mo5`) is
an ancestor of `BETA`, so the release PR is a fast-forward and nothing is lost by
merging it.

Check:

```bash
gh api repos/NggKhaiz/ZMRIG --jq .default_branch       # BETA
git ls-remote origin refs/heads                       # BETA and master at the same commit
gh pr list --state merged | head -2                   # the release PR shows as merged
git diff --stat origin/BETA origin/master             # empty
```

Cleanup after the merge — the only branch left over is the session branch:

```bash
git push origin --delete arena/918a7f95-xmrig-ocean    # closes nothing; the PR is already merged
# stale session tips, if any were left behind:
git ls-remote --heads origin 'arena/*'
```

**Do not rename** the session branch to `BETA`: it is assigned per session, the
whole point of `BETA` is to be the stable default, and the two would fight over
the same name on the next push.

---

## 2. Repository settings

Nothing in the tree can change these, and the API call needs *Administration*
permission (this session's token gets `403`). Paste them in **Settings → General**:

* **Description**
  `Monero (RandomX) miner with a 0% developer fee you can verify, a Zig frontend, one-click install, and a self-hosted pool. No donation code in the binary.`
  The current description is upstream's algorithm list and does not match what
  this repository is.
* **Topics**
  `monero` `randomx` `miner` `xmrig` `stratum` `zig` `cpu-mining`
* **Website**
  `https://nggkhaiz.github.io/ZMRIG/` — already set, and correct once step 4 is
  done. Change it if you use a custom domain.

The **Sponsor** button needs no setting: `.github/FUNDING.yml` points it at the
donation section of the README. It renders once the file exists on the default
branch (`BETA`), which it now does.

Check: open the repository page — a Sponsor button, the new description and the
topics are visible.

---

## 3. CI: the site job

`.github/workflows/test.yml` builds the C++ miner on Linux x64/arm64, macOS and
Windows. It does **not** run the site tests, because adding a job means editing a
file under `.github/workflows/`, and that needs the `workflows` token scope —
this environment has no such token, so the push is rejected. Everything else is
ready; the job is four lines of YAML.

Create **`.github/workflows/site.yml`** (new file, so no merge conflict with
upstream):

```yaml
name: Site tests

on:
  push:
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  site:
    name: Site tests and donation guard
    runs-on: ubuntu-24.04
    timeout-minutes: 10

    steps:
      - name: Checkout code
        uses: actions/checkout@v5

      - name: Set up Node
        uses: actions/setup-node@v5
        with:
          node-version: '22'

      # package-lock.json is not committed, so this is `npm install`, not `npm ci`.
      # --no-save keeps package.json untouched inside the runner.
      - name: Install jsdom
        run: npm install --no-audit --no-fund --no-save jsdom

      - name: Run site tests
        run: npm run test:web
```

What it proves: the command builder assembles the flags it promises, every
documentation page renders, raw HTML in Markdown stays escaped, `javascript:`
links are dropped, and **every published copy of the donation address equals the
wallet `pool/src/operator.js` decodes to** — a typo in an address fails the build
instead of sending somebody's money nowhere.

Do the same edit in the GitHub web editor if you prefer: *Add file → Create new
file*, paste, commit straight to `BETA`. There is no scope problem on the web UI
because there the token is yours, not this session's.

Check:

```bash
gh workflow list                      # "Site tests" appears
gh run list --workflow site.yml       # a green run after the next push
```

### Optional: the release workflow

`.github/workflows/deploy.yml` triggers on tags `v*`, builds Windows/Linux/macOS
artifacts and publishes a GitHub release. Its last two steps push into
`MoneroOcean/xmrig_setup` and `MoneroOcean/hiveos` using the secret
`xmrig_setup_key`. **Leave that secret unset**: the steps detect it is missing,
print `xmrig_setup_key is not configured; skipping`, and the release is still
created. Only set it if you really do own those upstream repositories.

Do not delete the workflow — Windows/macOS artifacts are the only way most users
get a prebuilt binary.

---

## 4. Publish the documentation site

`web/` is static: no build step, no framework, no analytics. Three ways to host
it; pick one. GitHub Pages matches the `homepage` field that is already set.

### 4a. GitHub Pages (matches the `homepage` field)

Pages is currently **disabled** (`has_pages: false`). Pages cannot serve a
subdirectory of a branch, so it needs a workflow too — same scope problem as
above, so create **`.github/workflows/pages.yml`** by hand:

```yaml
name: Deploy site

on:
  push:
    branches: [BETA]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout code
        uses: actions/checkout@v5

      - name: Configure Pages
        uses: actions/configure-pages@v5

      - name: Upload the site
        uses: actions/upload-pages-artifact@v3
        with:
          path: web

  deploy:
    needs: build
    runs-on: ubuntu-24.04
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - name: Deploy
        id: deployment
        uses: actions/deploy-pages@v4
```

Then **Settings → Pages → Build and deployment → Source: GitHub Actions**
(not "Deploy from a branch").

The site uses relative links (`docs.html`, `assets/…`), so it works under the
`/ZMRIG/` sub-path without changes. `web/404.html` is picked up automatically by
Pages. `web/_headers` is a Cloudflare Pages file and is ignored by GitHub Pages —
the CSP then comes from the `<meta>` tags already in the pages; if you want real
response headers, use 4b.

Check:

```bash
curl -sI https://nggkhaiz.github.io/ZMRIG/ | head -3        # 200
curl -s  https://nggkhaiz.github.io/ZMRIG/robots.txt        # User-agent: *
```

### 4b. Cloudflare Pages (best headers, free)

Connect the repository, then set:

| Field | Value |
|---|---|
| Framework preset | None |
| Build command | *(empty)* |
| Build output directory | `web` |

`web/_headers` is honoured here, so the strict CSP (no inline script, no
third-party origin except `api.coingecko.com`) is sent as a real header.

### 4c. Vercel

Import the repository, **Root Directory = `web`**, Framework preset *Other*,
build command empty, output directory `.`. `web/vercel.json` already carries the
same CSP and cache headers. Or from a terminal:

```bash
cd web && npx vercel deploy --prod
```

### After choosing a domain

`web/sitemap.xml` and `web/robots.txt` contain absolute URLs for
`https://nggkhaiz.github.io/ZMRIG/`. If you deploy elsewhere, one command fixes
both the files and every cross-reference:

```bash
NEW=https://pool.example.com
sed -i "s#https://nggkhaiz.github.io/ZMRIG#$NEW#g" web/sitemap.xml web/robots.txt web/index.html web/docs.html README.md
grep -rn "nggkhaiz.github.io" web README.md    # must print nothing
```

---

## 5. Deploy the pool

The pool needs what a VPS is good at: a long-lived TCP socket and a Monero node.
It does **not** need a domain of its own if you use WebSocket mode.

**Before anything else you need `DAEMON`** — the URL of a `monerod` you control
(`http://127.0.0.1:18081` on the same box, or an `https://` node elsewhere). A
public node will rate-limit a pool into uselessness. `monerod` wants ~100 GB of
disk; that is the one real cost of running a pool.

### 5a. Render (free tier, WebSocket only)

`render.yaml` in the repository root is a blueprint: *New → Blueprint → point at
this repository*. Then in the service's **Environment** tab set the one value
marked `sync: false`:

```
DAEMON = https://your-node.example:18081
```

Leave `OPERATOR_ADDRESS` empty to use the wallet in `pool/src/operator.js`, or
set your own (the fee goes to whoever is listed at `/api/config`). `POOL_FEE_PERCENT=1`
is already in the blueprint.

Miners then connect with:

```bash
zmrig -o wss://<service>.onrender.com/stratum -u 4YourAddress.rig1 -t 2
```

Free instances sleep after 15 minutes without traffic, and a sleeping pool earns
nothing and loses its in-memory ledger. Fine for a test; use the paid instance or
Fly for real miners.

Check: `curl -s https://<service>.onrender.com/healthz` → `{"ok":true,…}`.

### 5b. Fly.io (raw TCP stratum, persistent ledger)

```bash
fly launch --no-deploy --dockerfile deploy/Dockerfile --copy-config
fly volumes create pool_data --size 1
fly secrets set DAEMON=https://your-node.example:18081
fly deploy
curl -s https://<app>.fly.dev/healthz
```

`fly.toml` maps `3333/tcp` (stratum), `8080/tcp` (HTTP + WS) and mounts the
volume at `/data`, which is where `STATE_FILE` and `AUDIT_FILE` live. Without the
volume the PPLNS ledger is lost on every restart.

### 5c. Cloudflare Worker bridge (only if your miners cannot reach the pool)

A stateless WebSocket ⇄ TCP bridge, free Workers plan:

```bash
cd pool/worker
npx wrangler deploy --var POOL_HOST:pool.example.com --var POOL_PORT:3333
# or edit [vars] in wrangler.toml and run: npx wrangler deploy
```

Miners then use `wss://ocean-pool-bridge.<account>.workers.dev/stratum`. The
Worker cannot reach a private address, so `POOL_HOST` must be publicly routable.

### 5d. Never commit pool money data

`pool/data/` (ledger + `audit.jsonl`) is gitignored on purpose. Keep it that way:
a ledger in git is a payout history in public, and a bad merge is a wrong payout.

---

## 6. Put one miner on it

On the box that mines, as a user with `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/NggKhaiz/ZMRIG/BETA/oneclick.sh \
  | sudo bash -s -- install --wallet 4YourMoneroAddress... --engine zmrig
```

Then:

```bash
sudo ./oneclick.sh status      # service, hashrate, accepted shares
sudo ./oneclick.sh verify      # FEE-FREE: 0% developer fee, verified.
sudo ./oneclick.sh report --power 95   # ZMRIG1. code for the fleet calculator
```

Restrictive egress (only 443 out) needs one extra flag:

```bash
sudo ./oneclick.sh config --wallet 4YourMoneroAddress... \
  --pool wss://pool.example.com/stratum --cloudflare --force
sudo ./oneclick.sh restart
```

Check the first share lands: `sudo ./oneclick.sh logs | grep -m1 accepted`.

---

## 7. Optional, once it works

* **Branch protection** on `BETA`: require the *Site tests* and build checks
  before merge. Settings → Branches → Add rule. Keep it off `master`, the PR
  flow already covers it.
* **Custom domain**: Cloudflare Pages → Custom domains, then run the `sed`
  command in §4 to update the sitemap.
* **A tag** for a real release: `git tag v6.26.0-mo9 && git push origin v6.26.0-mo9`
  runs `deploy.yml` and publishes prebuilt binaries.
* **Delete** the session branch when no more agent work is running:
  `git push origin --delete arena/918a7f95-xmrig-ocean`. Nothing else is left:
  the old `BETA` snapshot commit was deleted after its tree was compared
  byte-for-byte with the release commit (`223ce60…`, identical).

---

## What this environment cannot do, and why

| Blocked | Reason | Workaround |
|---|---|---|
| Editing `.github/workflows/*` | the token has no `workflows` scope; pushes are rejected | paste the two YAML files above in the web editor (§3, §4a) |
| Repository description, topics, Pages, branch protection | API returns `403` for repository administration | Settings UI (§2, §4) |
| DNS, custom domains | no access to your registrar or Cloudflare account | §4, §7 |
| Render / Fly / Vercel deploys | need your account and billing | §5 |
| Publishing a prebuilt binary | would need the release workflow, which is workflow-scope | tag from your own machine (§7) |
| `raw.githubusercontent.com` smoke test | unreachable from the sandbox | run the one-liner yourself (§6) |
| MSR / 1 GiB page measurements | the sandbox has no MSR access and cannot reserve a 1 GiB page | measured on bare metal by whoever has one; docs say so instead of guessing |

Everything else — the miner, the pool, the installer, the tests, the docs, the
site — is in the tree and runs locally:

```bash
./zmrig/tests/run.sh && ./zmrig/tests/unit.sh && ./zmrig/tests/cli.sh
./zmrig/tests/net.sh --quick
npm run test:web && npm run test:pool
./scripts/verify-fee-free.sh --source-only
python3 -m http.server -d web 8080
```
