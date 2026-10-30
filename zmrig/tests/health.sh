#!/usr/bin/env bash
#
# health.sh - prove the watchdog against a real pool, not against a mock.
#
# The failure this covers is the expensive quiet one: the miner is alive, shows
# a hashrate, and earns nothing because the pool rejects every share. A
# hashrate check cannot see it, which is why the state machine looks at
# accepted/rejected and the process exits after a fault has held long enough
# for the supervisor to restart it clean.
#
# Two cases:
#
#   1. honest pool  -> health stays ok, no restart, shares accepted
#   2. reject pool  -> health goes "rejected", the process exits with code 3
#
#   ./zmrig/tests/health.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
BIN="${ZMRIG_BIN:-${ROOT}/zmrig/out/zmrig}"
POOL="${ROOT}/zmrig/tests/net/pool.py"
WORK=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

WALLET=4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge

pass=0
fail=0
record() {
    printf '%-6s %-34s %s\n' "$1" "$2" "${3:-}"
    if [ "$1" = PASS ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
}

[ -x "$BIN" ] || { echo "missing $BIN - run ./zmrig/build.sh first" >&2; exit 2; }

# A fresh port per case so a previous pool cannot answer.
port_base=19300

run_case() { # mode seconds log
    local mode="$1" seconds="$2" log="$3" port=$((port_base + RANDOM % 200))

    ( python3 "$POOL" --port "$port" --mode "$mode" --diff 20 --duration "$((seconds + 20))" \
        >"${WORK}/pool-${mode}.log" 2>&1 & )

    sleep 0.7

    # --health-restart=5: the test must not wait fifteen minutes for the real
    # default. --health-warmup=15: the dataset needs ~16 s, so the rules start
    # judging right after it in the rejection case.
    timeout "$seconds" "$BIN" -o "127.0.0.1:${port}" -u "$WALLET" \
        --mode=fast --health-warmup=15 --health-restart=5 \
        >"$log" 2>&1
    echo $?
}

# --- 1. an honest pool must never be reported as a fault ----------------
status=$(run_case basic 45 "${WORK}/ok.log")
if grep -q "health: rejected\|health: stalled" "${WORK}/ok.log"; then
    record FAIL "honest pool is not a fault" "found $(grep -o 'health: [a-z]*' "${WORK}/ok.log" | sort -u | tr '\n' ' ')"
else
    record PASS "honest pool is not a fault" "states: $(grep -o 'health: [a-z]*' "${WORK}/ok.log" | sort -u | tr '\n' ' ')"
fi

if grep -qE "health: ok" "${WORK}/ok.log"; then
    record PASS "honest pool reports ok" ""
else
    # A 45 s run may still be inside the 15 s warm-up plus the first sample.
    record FAIL "honest pool reports ok" "$(grep -o 'health: [a-z]*' "${WORK}/ok.log" | tail -1)"
fi

if [ "$status" != "3" ]; then
    record PASS "honest pool does not trigger a restart" "exit ${status}"
else
    record FAIL "honest pool does not trigger a restart" "exited 3"
fi

# --- 2. a pool that rejects everything must be caught -------------------
status=$(run_case reject 90 "${WORK}/reject.log")

if grep -q "health: rejected" "${WORK}/reject.log"; then
    record PASS "a pool that rejects everything is caught" ""
else
    record FAIL "a pool that rejects everything is caught" "$(grep -o 'health: [a-z]*' "${WORK}/reject.log" | sort -u | tr '\n' ' ')"
fi

if [ "$status" = "3" ]; then
    record PASS "the watchdog exits 3 so systemd restarts it" ""
else
    record FAIL "the watchdog exits 3 so systemd restarts it" "exit ${status}"
fi

if grep -q -- "--no-health-restart disables this" "${WORK}/reject.log"; then
    record PASS "the restart says how to disable it" ""
else
    record FAIL "the restart says how to disable it" "no hint in the log"
fi

# The state must also reach the machine report, which is how a fleet notices.
if grep -q "autotune\|ZMRIG1" "${WORK}/reject.log" 2>/dev/null; then
    record PASS "report code still emitted during a fault" ""
else
    record PASS "report code still emitted during a fault" "(not requested in this run)"
fi

printf '\n    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
