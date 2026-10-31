#!/usr/bin/env bash
#
# links.sh - every relative link in the documentation points at a file.
#
# A dead link in a README is the cheapest possible way to look unfinished, and
# it is invisible until somebody clicks it. This walks every Markdown file at
# the top two levels, extracts the relative targets and checks them. Anchors are
# checked against the headings of the file they point into, so a renamed
# section fails here instead of on GitHub.
#
#   bash tests/docs/links.sh
#
# Exit code 0 when every link resolves, 1 otherwise.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
cd "$ROOT" || exit 2

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf ' PASS %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf ' FAIL %s\n' "$1"; }

files=()
while IFS= read -r file; do files+=("$file"); done < <(
    find . -name node_modules -prune -o \
         \( -path './.git' -o -path './build' -o -path './zmrig/out' -o -path './src/3rdparty' \) -prune -o \
         -name '*.md' -print | sort
)

[ "${#files[@]}" -gt 0 ] || { echo "no Markdown files found" >&2; exit 2; }

# GitHub slugger: lowercase, drop punctuation, spaces to dashes.
slug() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[`*_]//g' \
              -e 's/[^a-z0-9 -]//g' \
              -e 's/  */ /g' \
              -e 's/ /-/g' \
              -e 's/^-//' -e 's/-$//'
}

# Markdown under web/content/ is not read from disk: docs.js renders it inside
# docs.html, so its relative links resolve against web/. Treat it that way here
# or every wizard link would look broken.
base_dir() {
    case "$1" in
        ./web/content/*) echo "./web" ;;
        *) echo "$(dirname "$1")" ;;
    esac
}

for file in "${files[@]}"; do
    dir=$(base_dir "$file")

    # Inline links and images: [text](target) / ![alt](target)
    while IFS= read -r target; do
        [ -z "$target" ] && continue
        case "$target" in
            http://*|https://*|mailto:*|'#'*|*'{{'*) continue ;;
        esac

        path=${target%%#*}
        anchor=""
        case "$target" in
            *'#'*) anchor=${target#*#} ;;
        esac

        # A site route (`/docs/pools/choosing`) is a Docusaurus page, not a file
        # relative to the Markdown it was written in. Resolve it against the
        # docs directory; the built site is checked by tests/docs/pages.sh.
        case "$path" in
            /docs/*)
                route=${path#/docs/}
                route=${route%/}
                if [ -f "site/docs/${route}.md" ] || [ -f "site/docs/${route}.mdx" ] \
                   || [ -f "site/docs/${route%/}/index.md" ]; then
                    ok "$file -> $path (site route)"
                else
                    bad "$file -> $path (no such page in site/docs)"
                fi
                continue
                ;;
            /*) continue ;;
        esac

        if [ -n "$path" ]; then
            # Strip a trailing query string, which only matters for site links.
            path=${path%%\?*}
            resolved="$dir/$path"
            if [ -e "$resolved" ]; then
                ok "$file -> $path"
            else
                bad "$file -> $path (missing)"
                continue
            fi
        else
            resolved="$file"
        fi

        if [ -n "$anchor" ] && [ -f "$resolved" ]; then
            case "$resolved" in
                *.md)
                    found=0
                    while IFS= read -r heading; do
                        text=$(printf '%s' "$heading" | sed -e 's/^#* *//' -e 's/ *$//')
                        if [ "$(slug "$text")" = "$anchor" ]; then found=1; break; fi
                    done < <(grep -E '^#{1,6} ' "$resolved" 2>/dev/null)
                    if [ "$found" = 1 ]; then
                        ok "$file -> $path#$anchor"
                    else
                        bad "$file -> $path#$anchor (no such heading)"
                    fi
                    ;;
                *.html)
                    # docs.html is a shell: its anchors are slugs from the
                    # manifest, not ids in the markup.
                    if [ "$(basename "$resolved")" = "docs.html" ]; then
                        if grep -q "\"slug\": *\"$anchor\"" web/content/vi/index.json 2>/dev/null; then
                            ok "$file -> $path#$anchor"
                        else
                            bad "$file -> $path#$anchor (no such page in index.json)"
                        fi
                        continue
                    fi

                    if grep -q "id=\"$anchor\"" "$resolved" 2>/dev/null; then
                        ok "$file -> $path#$anchor"
                    else
                        bad "$file -> $path#$anchor (no such id)"
                    fi
                    ;;
            esac
        fi
    done < <(grep -oE '\]\([^)]+\)' "$file" 2>/dev/null | sed -e 's/^](//' -e 's/)$//' | sort -u)
done

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
