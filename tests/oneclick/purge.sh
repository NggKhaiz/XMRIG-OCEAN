#!/usr/bin/env bash
#
# purge.sh - `oneclick.sh purge` is destructive, so it gets a test that runs it.
#
# The installer has two removal paths and they promise different things:
#
#   uninstall  remove the service and the binaries, keep the config and the
#              build cache (re-installing is common)
#   purge      remove everything the tool put on the machine, including the
#              config, the state directory and the clone
#
# A purge that removes too little is a lie; one that removes too much is a
# disaster, so this test checks both directions against a temporary tree:
#
#   * --dry-run lists every path and deletes nothing,
#   * a real run deletes exactly those paths,
#   * a file outside them (the "wallet backup") is still there afterwards.
#
#   ./tests/oneclick/purge.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { printf ' PASS %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAILED=1; }

# A sandbox that looks like a real install: binaries, config with a wallet,
# state, build cache, service units, and one file the tool does not own.
PREFIX="${WORK}/usr-local"
CONFIG="${WORK}/etc-xmrig-ocean"
STATE="${WORK}/var-lib"
BUILD="${WORK}/build"
UNITS="${WORK}/systemd"
KEEP="${WORK}/wallet-backup.txt"

mkdir -p "${PREFIX}/bin" "${CONFIG}" "${STATE}" "${BUILD}" "${UNITS}"
printf '#!/bin/sh\n' > "${PREFIX}/bin/xmrig-ocean"
printf '#!/bin/sh\n' > "${PREFIX}/bin/zmrig"
printf '{"pools":[{"user":"4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"}]}\n' > "${CONFIG}/config.json"
printf 'zmrig\n' > "${CONFIG}/engine"
printf '{"shares":1}\n' > "${STATE}/state.json"
printf 'object code\n' > "${BUILD}/miner.o"
printf '[Unit]\n' > "${UNITS}/xmrig-ocean.service"
printf '[Unit]\n' > "${UNITS}/xmrig-ocean-tune.service"
printf 'my wallet, in a place the tool does not own\n' > "$KEEP"

run_purge() {
    MINER_PREFIX="$PREFIX" MINER_CONFIG_DIR="$CONFIG" MINER_STATE_DIR="$STATE" \
    MINER_BUILD_DIR="$BUILD" MINER_SERVICE_DIR="$UNITS" \
        bash "$ROOT/oneclick.sh" purge "$@" 2>&1
}

# --- 1. dry run lists the install and touches nothing ----------------------
out=$(run_purge --dry-run)
status=$?

if [ "$status" -eq 0 ]; then
    pass "purge --dry-run exits 0"
else
    fail "purge --dry-run exited ${status}"
fi

if printf '%s' "$out" | grep -q "$CONFIG"; then
    pass "dry run lists the config directory"
else
    fail "dry run did not mention ${CONFIG}"
fi

if printf '%s' "$out" | grep -q "nothing will be removed"; then
    pass "dry run says it will remove nothing"
else
    fail "dry run did not state that it removes nothing"
fi

survivors=0
for path in "${PREFIX}/bin/zmrig" "${CONFIG}/config.json" "${STATE}/state.json" "${BUILD}/miner.o"; do
    [ -e "$path" ] || survivors=$((survivors + 1))
done

if [ "$survivors" -eq 0 ]; then
    pass "dry run deleted nothing"
else
    fail "dry run deleted ${survivors} path(s)"
fi

# --- 2. a real run removes exactly the install ----------------------------
out=$(run_purge --yes)
status=$?

if [ "$status" -eq 0 ]; then
    pass "purge --yes exits 0"
else
    fail "purge --yes exited ${status} (output: $(printf '%s' "$out" | tail -3))"
fi

gone=0
missing=0
for path in "${PREFIX}/bin/xmrig-ocean" "${PREFIX}/bin/zmrig" "${CONFIG}" "${STATE}" "${BUILD}" \
            "${UNITS}/xmrig-ocean.service" "${UNITS}/xmrig-ocean-tune.service"; do
    if [ -e "$path" ]; then
        missing=$((missing + 1))
        printf '      still present: %s\n' "$path"
    else
        gone=$((gone + 1))
    fi
done

if [ "$missing" -eq 0 ]; then
    pass "every install path was removed (${gone})"
else
    fail "${missing} install path(s) survived the purge"
fi

# --- 3. it removed nothing it does not own -------------------------------
if [ -f "$KEEP" ]; then
    pass "a file outside the install survived"
else
    fail "purge deleted ${KEEP}, which it does not own"
fi

if [ -d "$WORK" ]; then
    pass "the parent directory was not removed"
else
    fail "purge removed the parent directory"
fi

# --- 4. a second run is a no-op, not an error ----------------------------
out=$(run_purge --dry-run)
if [ "$?" -eq 0 ] && printf '%s' "$out" | grep -q "no install found"; then
    pass "purging an already clean machine is a no-op"
else
    fail "purging twice misbehaved: $(printf '%s' "$out" | tail -2)"
fi

# --- 5. unattended purge without --yes must refuse -----------------------
# Recreate one path so there is something to delete.
mkdir -p "$CONFIG"
printf '{}\n' > "${CONFIG}/config.json"
out=$(run_purge < /dev/null)
if [ "$?" -ne 0 ] && printf '%s' "$out" | grep -q "refusing to purge"; then
    pass "an unattended purge without --yes is refused"
else
    fail "an unattended purge without --yes was not refused"
fi

if [ -f "${CONFIG}/config.json" ]; then
    pass "the refused purge left the config alone"
else
    fail "the refused purge still deleted the config"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "purge: all checks passed"
    exit 0
fi

echo "purge: FAILED"
exit 1
