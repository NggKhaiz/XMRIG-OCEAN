#!/usr/bin/env bash
#
# submit-latency.sh - what a slow or stalled pool costs the hashrate.
#
# The worker threads used to hand their shares to the pool synchronously, under
# a mutex shared with the keepalive thread. A socket write returns quickly while
# the kernel send buffer has room, so a healthy pool costs nothing -- but a pool
# that stops reading (dead route, zero window, a relay that wedged) fills the
# buffer, and then every worker that finds a share blocks in write() for up to
# the 5 s send timeout, holding a mutex the other workers need.
#
# This script measures that directly: the same binary, the same job difficulty,
# three pools that differ only in how they treat the socket.
#
#   ./zmrig/tests/submit-latency.sh            # 30 s per case
#   ./zmrig/tests/submit-latency.sh --seconds 45
#   ZMRIG_BIN=build/zmrig ./zmrig/tests/submit-latency.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
BIN="${ZMRIG_BIN:-${ROOT}/zmrig/out/zmrig}"
POOL="${ROOT}/zmrig/tests/net/pool.py"
SECONDS_PER_CASE=30
PORT_BASE=4811
WALLET="4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"
# 1 share in 20 hashes: at ~1 kH/s that is ~50 shares a second, so a blocking
# send path shows up in the first second instead of after a minute.
DIFF=20

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds)   SECONDS_PER_CASE="${2:?}"; shift ;;
        --seconds=*) SECONDS_PER_CASE="${1#*=}" ;;
        -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -x "$BIN" ] || { echo "no binary at $BIN (run ./zmrig/build.sh)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; pkill -f "pool.py --mode .* --port ${PORT_BASE}" 2>/dev/null || true' EXIT

# Runs one case and prints the median of the hashrate samples after warm-up.
run_case() {
    local name="$1" mode="$2" port="$3"
    local log="${tmp}/${name}.log"

    python3 "$POOL" --mode "$mode" --port "$port" --diff "$DIFF" \
        --lifetime "$((SECONDS_PER_CASE + 20))" --duration "$((SECONDS_PER_CASE + 10))" \
        > "${tmp}/${name}.pool" 2>&1 &
    local pool_pid=$!
    sleep 1

    # The dataset takes ~16 s to build; only sample after it is up.
    timeout "$((SECONDS_PER_CASE + 25))" "$BIN" -o "127.0.0.1:${port}" -u "$WALLET" \
        --no-color --print-time 5 > "$log" 2>&1

    kill "$pool_pid" 2>/dev/null
    wait "$pool_pid" 2>/dev/null

    # XMRig's line shape: "speed 10s/60s/15m 1.07k 1.07k 1.07k H/s max 1.09k H/s".
    # Take the 10 s figure from every sample and use the median, so a single
    # slow sample (dataset swap, job switch) cannot decide the result.
    local value
    value=$(grep -oE 'speed 10s/60s/15m [0-9.]+[kM]? ' "$log" \
        | awk '{ v = $3
                 if (v ~ /k$/) { sub(/k$/, "", v); v *= 1000 }
                 else if (v ~ /M$/) { sub(/M$/, "", v); v *= 1000000 }
                 print v }' \
        | sort -n | awk '{ a[NR] = $1 } END {
              if (NR == 0) { print "0"; exit }
              print a[int((NR + 1) / 2)] }')

    local submits dropped
    submits=$(grep -oE 'submits=[0-9]+' "${tmp}/${name}.pool" | tail -1 | cut -d= -f2)
    dropped=$(grep -c 'share found while disconnected' "$log" 2>/dev/null || true)

    printf '%-12s %10.1f H/s   submits=%-6s dropped=%s\n' \
        "$name" "${value:-0}" "${submits:-0}" "${dropped:-0}"
}

echo "zmrig share submission: ${SECONDS_PER_CASE}s per case, difficulty ${DIFF}"
echo "binary: ${BIN}"
echo
printf '%-12s %10s        %s\n' "pool" "hashrate" "notes"
printf '%-12s %10s        %s\n' "----" "--------" "-----"

run_case "healthy" basic "$PORT_BASE"
run_case "stalled" deaf "$((PORT_BASE + 1))"

echo
echo "A healthy pool and a pool that stopped reading must produce the same"
echo "hashrate. A gap means share submission is blocking the hash loop."
