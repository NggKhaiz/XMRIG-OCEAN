#!/usr/bin/env bash
#
# pages.sh - the site as GitHub Pages will actually serve it.
#
# The site is published from web/, but Pages can be pointed at a branch root,
# at the Actions artifact, or at a custom domain. Every one of those has broken
# at least once, always with the same useless symptom: a 404 page. These checks
# are the machine version of clicking through the deployed site.
#
#   bash tests/docs/pages.sh
#
# Exit code 0 when the site would survive being published, 1 otherwise.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
cd "$ROOT" || exit 2

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf ' PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf ' FAIL %s\n' "$1"; }

# --- 1. the two publishing modes both land on a page -----------------------
for entry in web/index.html; do
    [ -f "$entry" ] && ok "entry point exists: ${entry}" || bad "missing ${entry}"
done

for file in index.html 404.html .nojekyll web/.nojekyll; do
    [ -f "$file" ] && ok "branch-root fallback present: ${file}" || bad "missing ${file}"
done

if grep -q 'url=web/' index.html && grep -q 'location.replace("web/"' index.html; then
    ok "index.html redirects to web/ (with and without JavaScript)"
else
    bad "index.html does not redirect to web/ for both JS and no-JS"
fi

if grep -q '/web/' 404.html; then
    ok "404.html can rewrite a deep link into web/"
else
    bad "404.html does not know about web/"
fi

# --- 2. no root-absolute paths: Pages serves this under /<repo>/ -----------
absolute=$(grep -rnoE '(href|src)="/[^/]' web/*.html web/assets/*.js web/assets/*.css 2>/dev/null | head -5)
if [ -z "$absolute" ]; then
    ok "no root-absolute links (works under a /<repo>/ sub-path)"
else
    bad "root-absolute link(s) break on a project page:"
    printf '      %s\n' "$absolute"
fi

# --- 3. every local href/src in the pages exists ---------------------------
# Each reference is checked by hand and counted; the counter is what the test
# reports, so a page whose markup changed shape cannot pass silently by
# producing zero references.
checked=0
missing=0
for page in web/*.html; do
    dir=$(dirname "$page")
    while IFS= read -r target; do
        case "$target" in
            ""|\#*|http://*|https://*|//*|mailto:*|data:*|javascript:*) continue ;;
        esac
        path=${target%%\#*}
        path=${path%%\?*}
        [ -z "$path" ] && continue
        checked=$((checked + 1))
        if [ ! -e "${dir}/${path}" ] && [ ! -e "web/${path}" ]; then
            missing=$((missing + 1))
            printf '      %s -> %s\n' "$page" "$target"
        fi
    done < <(grep -oE '(href|src)="[^"]+"' "$page" | sed -e 's/^href="//' -e 's/^src="//' -e 's/"$//' | sort -u)
done
if [ "$checked" -lt 10 ]; then
    bad "only ${checked} local reference(s) found in web/*.html; the check is not reading the pages"
elif [ "$missing" -eq 0 ]; then
    ok "every local href/src in web/*.html resolves (${checked} checked)"
else
    bad "${missing} of ${checked} local reference(s) broken, listed above"
fi

# --- 3b. every in-site #anchor exists ------------------------------------
# A link to index.html#builder that lands on a page without id="builder" is a
# dead end with no error anywhere: the browser just scrolls to the top.
anchors_checked=0
anchors_broken=0
for page in web/*.html; do
    while IFS= read -r target; do
        case "$target" in
            ""|http://*|https://*|mailto:*) continue ;;
        esac
        case "$target" in
            *"#"*) ;;
            *) continue ;;
        esac
        target_page=${target%%#*}
        anchor=${target#*#}
        [ -z "$anchor" ] && continue
        [ -z "$target_page" ] && target_page=$(basename "$page")
        anchors_checked=$((anchors_checked + 1))

        # docs.html renders one page at a time from web/content/vi/index.json,
        # so its anchors are slugs in the manifest, not ids in the markup.
        if [ "$target_page" = "docs.html" ]; then
            grep -q "\"slug\": *\"$anchor\"" web/content/vi/index.json 2>/dev/null \
                || { anchors_broken=$((anchors_broken + 1)); printf '      %s -> %s (no such docs page)\n' "$page" "$target"; }
            continue
        fi

        grep -q "id=\"$anchor\"" "web/${target_page}" 2>/dev/null \
            || { anchors_broken=$((anchors_broken + 1)); printf '      %s -> %s (no such id in %s)\n' "$page" "$target" "$target_page"; }
    done < <(grep -oE 'href="[^"]*#[^"]*"' "$page" | sed -e 's/^href="//' -e 's/"$//' | sort -u)
done
if [ "$anchors_broken" -eq 0 ]; then
    ok "every in-site #anchor resolves (${anchors_checked} checked)"
else
    bad "${anchors_broken} of ${anchors_checked} in-site anchor(s) broken, listed above"
fi

# --- 3c. the CSP works without response headers --------------------------
# GitHub Pages ignores web/_headers, so the policy only exists as a <meta> tag
# on each page. A policy that forbids inline script while a page still has an
# inline <script> blocks the page silently: it renders, then nothing works.
csp_bad=0
for page in web/*.html; do
    grep -q 'http-equiv="Content-Security-Policy"' "$page" \
        || { csp_bad=$((csp_bad + 1)); printf '      %s has no CSP meta\n' "$page"; }
    if grep -q "script-src 'self'" "$page" && grep -qE '<script(>| [^>]*)>[^<]' "$page"; then
        csp_bad=$((csp_bad + 1))
        printf '      %s has an inline <script>, blocked by its own script-src\n' "$page"
    fi
done
if [ "$csp_bad" -eq 0 ]; then
    ok "every page carries a CSP meta tag and no page needs inline script"
else
    bad "${csp_bad} CSP problem(s) above"
fi

# --- 4. the files the docs shell fetches are in the artifact --------------
if [ -f web/content/vi/index.json ]; then
    ok "docs manifest shipped: web/content/vi/index.json"
else
    bad "web/content/vi/index.json is missing; docs.html renders nothing"
fi

manifest_missing=0
while IFS= read -r file; do
    [ -f "web/content/vi/${file}" ] || { manifest_missing=$((manifest_missing + 1)); printf '      missing content file: %s\n' "$file"; }
done < <(grep -oE '"file": *"[^"]+"' web/content/vi/index.json | sed -E 's/.*"([^"]+)"$/\1/')
if [ "$manifest_missing" -eq 0 ]; then
    ok "every page in the manifest has its Markdown file"
else
    bad "${manifest_missing} manifest entr(ies) point at missing files"
fi

# --- 5. the sitemap only advertises pages that exist ----------------------
sitemap_missing=0
while IFS= read -r url; do
    page=${url#https://nggkhaiz.github.io/ZMRIG/}
    page=${page%%#*}
    [ -z "$page" ] && page=index.html
    [ -f "web/${page}" ] || { sitemap_missing=$((sitemap_missing + 1)); printf '      sitemap advertises a missing page: %s\n' "$url"; }
done < <(grep -oE '<loc>[^<]+</loc>' web/sitemap.xml | sed -e 's|<loc>||' -e 's|</loc>||')
if [ "$sitemap_missing" -eq 0 ]; then
    ok "sitemap.xml advertises only pages that exist"
else
    bad "${sitemap_missing} sitemap entr(ies) point at missing pages"
fi

# --- 6. the workflow publishes web/ on a push to BETA ---------------------
workflow=".github/workflows/pages.yml"
if grep -q 'path: web' "$workflow" 2>/dev/null; then
    ok "${workflow} uploads web/ as the artifact"
else
    bad "${workflow} does not upload web/"
fi

if grep -qE '^\s+branches: \[BETA\]' "$workflow" 2>/dev/null; then
    ok "${workflow} triggers on a push to BETA (the branch the installer uses)"
else
    bad "${workflow} does not trigger on BETA"
fi

# --- 7. the branch-root 404 rewrites deep links into web/ -----------------
# The rewriting is the only part of this that is code rather than a file, so it
# gets executed with a fake location. It shipped once with "/ZMRIG/" turning
# into "/web/ZMRIG", which is why the first case below is the bare prefix.
if command -v node >/dev/null 2>&1; then
    redirect=$(node - <<'NODE'
const fs = require("fs");
const html = fs.readFileSync("404.html", "utf8");
const code = html.split("<script>")[1].split("</script>")[0];
const cases = [
  ["/ZMRIG/", "/ZMRIG/web/"],
  ["/ZMRIG/wizard.html", "/ZMRIG/web/wizard.html"],
  ["/ZMRIG/docs.html", "/ZMRIG/web/docs.html"],
  ["/ZMRIG/a/b.html", "/ZMRIG/web/a/b.html"],
  ["/wizard.html", "/web/wizard.html"],
  ["/", "/web/"],
  ["/ZMRIG/web/missing.html", ""],
  ["/web/missing.html", ""],
];
let bad = 0;
for (const [input, expected] of cases) {
  let to = "";
  new Function("location", "document", code)(
    { pathname: input, search: "", hash: "", replace(t) { to = t; } },
    { write() {} }
  );
  if (to !== expected) {
    console.log(`${input} -> ${to || "(no redirect)"}, expected ${expected || "(no redirect)"}`);
    bad++;
  }
}
process.exit(bad === 0 ? 0 : 1);
NODE
)
    if [ $? -eq 0 ]; then
        ok "404.html rewrites /ZMRIG/<deep link> into /ZMRIG/web/ (8 cases)"
    else
        bad "404.html rewrites the wrong path:"
        printf '      %s\n' "$redirect"
    fi
else
    printf ' SKIP 404.html rewrite (node not installed)\n'
fi

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
