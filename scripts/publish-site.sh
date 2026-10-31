#!/usr/bin/env bash
# Build the documentation site and copy it into the repository root.
#
# Why the output is committed instead of deployed from an artifact:
# GitHub Pages for this repository is configured as "Deploy from a branch →
# BETA → /", and that setting can only be changed from the repository settings
# page, not from a workflow token. So the branch root IS the published site, and
# Docusaurus `baseUrl: /ZMRIG/` expects its assets at /ZMRIG/assets/… .
#
# Only the directories Docusaurus owns are replaced. `web/` (the previous static
# site), `robots.txt`, `.nojekyll` and everything else in the repository are left
# alone, so nothing here can delete a file a human wrote.
#
#   ./scripts/publish-site.sh            build and publish
#   ./scripts/publish-site.sh --check    fail if the committed copy is stale
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/site"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

npm run build >/dev/null

STALE=""
for path in index.html 404.html search.html search-index.json sitemap.xml; do
  if ! cmp -s "build/$path" "$ROOT/$path"; then STALE="$STALE $path"; fi
done
for dir in assets docs vi img; do
  if ! diff -rq "build/$dir" "$ROOT/$dir" >/dev/null 2>&1; then STALE="$STALE $dir/"; fi
done

if [ "$CHECK" = 1 ]; then
  if [ -n "$STALE" ]; then
    echo "the committed site is stale:$STALE"
    echo "run ./scripts/publish-site.sh and commit the result"
    exit 1
  fi
  echo "the committed site matches site/build"
  exit 0
fi

rm -rf "$ROOT/assets" "$ROOT/docs" "$ROOT/vi"
cp -a build/. "$ROOT/"

echo "published $(find build -type f | wc -l) files to $ROOT"
echo "  https://nggkhaiz.github.io/ZMRIG/docs/intro"
echo "  https://nggkhaiz.github.io/ZMRIG/vi/docs/intro"
