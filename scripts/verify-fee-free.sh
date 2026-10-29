#!/usr/bin/env bash
#
# verify-fee-free.sh - prove that this build really mines 0% for the developer.
#
#   ./scripts/verify-fee-free.sh                 # source audit + binary audit
#   ./scripts/verify-fee-free.sh --source-only   # no binary required
#   ./scripts/verify-fee-free.sh --binary build/xmrig
#
# Exit code 0 means: no dev-fee code path, no dev wallet, no donation pool and
# the miner itself reports DONATE 0%.
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/.." && pwd)
BINARY="${ROOT}/build/xmrig"
SOURCE_ONLY=0
FAILED=0

color() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
pass() { printf ' %s %s\n' "$(color '1;32' 'PASS')" "$*"; }
fail() { printf ' %s %s\n' "$(color '1;31' 'FAIL')" "$*"; FAILED=1; }
info() { printf ' %s %s\n' "$(color '1;36' '*')" "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --source-only) SOURCE_ONLY=1 ;;
        --binary) BINARY="${2:?}"; shift ;;
        --binary=*) BINARY="${1#*=}" ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1"; exit 2 ;;
    esac
    shift
done

info "source audit"

# 1. The donation knobs must be zero.
level=$(grep -E 'kDefaultDonateLevel' "$ROOT/src/donate.h" | grep -oE '[0-9]+' | head -1)
if [ "${level:-1}" = "0" ]; then
    pass "kDefaultDonateLevel = 0"
else
    fail "kDefaultDonateLevel = ${level:-?} (expected 0)"
fi

min_level=$(grep -E 'kMinimumDonateLevel' "$ROOT/src/donate.h" | grep -oE '[0-9]+' | head -1)
if [ "${min_level:-1}" = "0" ]; then
    pass "kMinimumDonateLevel = 0"
else
    fail "kMinimumDonateLevel = ${min_level:-?} (expected 0)"
fi

# 2. The donation strategy must be gone, both from disk and from the build.
if [ -e "$ROOT/src/net/strategies/DonateStrategy.cpp" ] || [ -e "$ROOT/src/net/strategies/DonateStrategy.h" ]; then
    fail "DonateStrategy sources are still present"
else
    pass "DonateStrategy sources removed"
fi

if grep -q 'DonateStrategy' "$ROOT/CMakeLists.txt"; then
    fail "CMakeLists.txt still builds the donation strategy"
else
    pass "CMakeLists.txt does not build a donation strategy"
fi

if grep -rq 'DonateStrategy' "$ROOT/src" --include=*.cpp --include=*.h; then
    fail "src/ still references DonateStrategy"
else
    pass "src/ has no DonateStrategy references"
fi

# 3. No hardcoded developer wallet or donation endpoint anywhere in the runtime.
wallets=$(grep -rnoE '[48][1-9A-HJ-NP-Za-km-z]{94,106}' "$ROOT/src" --include=*.cpp --include=*.h --include=*.c 2>/dev/null \
    | grep -v '3rdparty/' | grep -v 'crypto/randomx/' || true)
if [ -n "$wallets" ]; then
    fail "hardcoded wallet address found:"
    printf '%s\n' "$wallets"
else
    pass "no hardcoded wallet address in src/"
fi

hosts=$(grep -rnoE '"([a-z0-9.-]*(donate|moneroocean)[a-z0-9.-]*\.[a-z]{2,})(:[0-9]+)?"' "$ROOT/src" --include=*.cpp --include=*.h 2>/dev/null || true)
if [ -n "$hosts" ]; then
    fail "donation endpoint still referenced:"
    printf '%s\n' "$hosts"
else
    pass "no donation endpoint in src/"
fi

# 4. Network must never build a second stratum session.
if grep -q 'm_donate' "$ROOT/src/net/Network.cpp" "$ROOT/src/net/Network.h"; then
    fail "Network still contains donation plumbing"
else
    pass "Network has no donation plumbing"
fi

if [ "$SOURCE_ONLY" -eq 1 ]; then
    info "binary audit skipped (--source-only)"
else
    info "binary audit"
    if [ ! -x "$BINARY" ]; then
        fail "binary not found: $BINARY"
    else
        version=$("$BINARY" --version 2>/dev/null | head -1)
        pass "binary: ${version}"

        if strings "$BINARY" | grep -qE '89TxfrUmqJJcb1V124WsUzA78Xa3UYHt7Bg8RGMhXVeZYPN8cE5CZEk58Y1m23ZMLHN7wYeJ9da5n5MXharEjrm41hSnWHL|48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD'; then
            fail "binary contains a developer wallet address"
        else
            pass "binary contains no developer wallet address"
        fi

        if strings "$BINARY" | grep -qE 'donate\.v2\.xmrig\.com|xmrig\.moneroocean\.stream'; then
            fail "binary contains a donation pool endpoint"
        else
            pass "binary contains no donation pool endpoint"
        fi

        tmp=$(mktemp)
        "$BINARY" --dry-run --url pool.example.com:3333 --user FEEAUDIT --donate-level=9 >"$tmp" 2>&1 || true
        # Both engines must prove the same thing in their own words: the C++
        # banner prints "DONATE 0%", zmrig answers the request with
        # "--donate-level=9 ignored ... 0% developer fee".
        if sed 's/\x1b\[[0-9;]*m//g' "$tmp" | grep -qE 'DONATE *0%|0% developer fee'; then
            pass "runtime keeps the fee at 0% even with --donate-level=9"
        else
            fail "runtime does not report a 0% fee"
            sed 's/\x1b\[[0-9;]*m//g' "$tmp" | grep -iE 'donate|fee' || true
        fi
        rm -f "$tmp"
    fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
    printf '%s\n' "$(color '1;32' 'FEE-FREE: 0% developer fee, verified.')"
    exit 0
fi

printf '%s\n' "$(color '1;31' 'FEE AUDIT FAILED')"
exit 1
