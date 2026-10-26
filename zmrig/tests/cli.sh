#!/usr/bin/env bash
#
# cli.sh - the command line is a contract: flags keep working, exit codes stay
# usable from scripts, and --help documents what the parser accepts.
#
#   ./zmrig/tests/cli.sh            # uses zmrig/out/zmrig
#   ZMRIG_BIN=/usr/local/bin/zmrig ./zmrig/tests/cli.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
BIN="${ZMRIG_BIN:-${ROOT}/zmrig/out/zmrig}"
SRC="${ROOT}/zmrig/src/options.zig"

[ -x "$BIN" ] || { echo "missing $BIN - run ./zmrig/build.sh first" >&2; exit 2; }

pass=0
fail=0

record() { # status name detail
    printf '%-6s %-28s %s\n' "$1" "$2" "${3:-}"
    if [ "$1" = PASS ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
}

# Expects an exact exit status; any output is only shown on failure.
expect_exit() { # wanted name -- command...
    local want="$1" name="$2"
    shift 3
    local out status
    out=$("$@" 2>&1)
    status=$?
    if [ "$status" -eq "$want" ]; then
        record PASS "$name" "exit $status"
    else
        record FAIL "$name" "wanted exit $want, got $status: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    fi
}

WALLET=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge

printf 'zmrig cli contract: %s\n\n' "$BIN"

# -- flags --------------------------------------------------------------
expect_exit 0 "help" -- "$BIN" --help
expect_exit 0 "version" -- "$BIN" --version
expect_exit 1 "unknown flag" -- "$BIN" --definitely-not-a-flag
expect_exit 1 "missing value" -- "$BIN" -o
expect_exit 1 "bad pool scheme" -- "$BIN" -o gopher://pool:1 -u "$WALLET"
expect_exit 1 "no pool" -- "$BIN" --check
expect_exit 1 "no wallet" -- "$BIN" -o pool.example.com:3333 --check
expect_exit 0 "valid config" -- "$BIN" -o pool.example.com:3333 -u "$WALLET" --check
expect_exit 0 "--dry-run is --check" -- "$BIN" -o pool.example.com:3333 -u "$WALLET" --dry-run
expect_exit 1 "donate-level > 100" -- "$BIN" -o pool.example.com:3333 -u "$WALLET" --donate-level 101
expect_exit 1 "unknown config file" -- "$BIN" -c /nonexistent/config.json --check

# A rejected configuration must not print the "config ok" summary.
if "$BIN" -o pool.example.com:3333 --check 2>/dev/null | grep -q 'config ok'; then
    record FAIL "no summary on rejection" "printed config ok without a wallet"
else
    record PASS "no summary on rejection" "no summary without a wallet"
fi

# -- help documents every flag the parser accepts ------------------------
documented=$("$BIN" --help | grep -oE '\-\-[a-z0-9-]+' | sort -u)
handled=$(grep -oE '"--[a-z0-9-]+"' "$SRC" | tr -d '"' | sort -u)

# Short aliases and the compatibility spellings that share a line in --help.
known_undocumented='^--(url|user|pass|password|algo|threads|config|rig-id|wrmsr|no-rdmsr|randomx-no-rdmsr|not-a-flag)$'

missing=$(comm -23 <(printf '%s\n' "$handled") <(printf '%s\n' "$documented") | grep -vE "$known_undocumented" || true)
if [ -z "$missing" ]; then
    record PASS "--help covers the parser" "$(printf '%s\n' "$handled" | wc -l) flags"
else
    record FAIL "--help covers the parser" "missing: $(printf '%s' "$missing" | tr '\n' ' ')"
fi

# -- no flag is accepted and then ignored -------------------------------
# Every flag below must change something observable in --check or the log.
check_output=$("$BIN" -o pool.example.com:3333 -u "$WALLET" --cpu-affinity=0x1 --priority 3 \
    --randomx-init 1 --user-agent test-agent --check 2>&1)

for needle in "affinity 0x1" "priority 3" "dataset  built with 1 thread" "agent   test-agent"; do
    if printf '%s' "$check_output" | grep -qF "$needle"; then
        record PASS "flag visible: $needle" ""
    else
        record FAIL "flag visible: $needle" "not in --check output"
    fi
done

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
