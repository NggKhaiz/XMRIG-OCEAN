#!/usr/bin/env bash
#
# ab.sh - A/B benchmark of the zmrig knobs that can actually move hashrate.
#
# Every configuration runs the same number of hashes on the same machine, in
# isolation, and the script prints min/median/max so noise cannot be mistaken
# for a win. Run it on an idle machine: a live miner or a browser tab on the
# same cores makes every number worthless.
#
#   ./zmrig/tests/ab.sh                  # 3 runs per config, 20k hashes each
#   ./zmrig/tests/ab.sh --runs 5 --hashes 40000
#   ./zmrig/tests/ab.sh --only default,prefetch0
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
BIN="${ZMRIG_BIN:-${ROOT}/zmrig/out/zmrig}"
RUNS=3
HASHES=20000
THREADS=""
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --runs)    RUNS="${2:?}"; shift ;;
        --runs=*)  RUNS="${1#*=}" ;;
        --hashes)  HASHES="${2:?}"; shift ;;
        --hashes=*) HASHES="${1#*=}" ;;
        --threads) THREADS=" -t ${2:?}"; shift ;;
        --threads=*) THREADS=" -t ${1#*=}" ;;
        --only)    ONLY="${2:?}"; shift ;;
        --only=*)  ONLY="${1#*=}" ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

[ -x "$BIN" ] || { echo "no binary at $BIN (run ./zmrig/build.sh)" >&2; exit 1; }
command -v awk >/dev/null || { echo "awk is required" >&2; exit 1; }

if pgrep -f "${BIN##*/} -o " >/dev/null 2>&1; then
    echo "!! a miner is running; its threads will skew every measurement" >&2
fi

# name|extra zmrig flags
CONFIGS=(
    "default|"
    "prefetch0|--scratchpad-prefetch=0"
    "prefetch2|--scratchpad-prefetch=2"
    "prefetch3|--scratchpad-prefetch=3"
    "no-jit-hugepages|--no-huge-pages-jit"
    "no-affinity|--no-affinity"
    "priority5|--priority=5"
    "light-mode|--mode=light"
)

median() {
    sort -n | awk '{ v[NR] = $1 } END {
        if (NR == 0) { print "0"; exit }
        if (NR % 2) { printf "%.2f\n", v[(NR + 1) / 2] }
        else        { printf "%.2f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }
    }'
}

printf 'zmrig A/B: %s hashes per run, %s run(s) per config\n' "$HASHES" "$RUNS"
printf 'binary: %s\n\n' "$BIN"
printf '%-18s %10s %10s %10s %10s\n' "config" "median" "min" "max" "spread"
printf '%-18s %10s %10s %10s %10s\n' "------" "------" "---" "---" "------"

for entry in "${CONFIGS[@]}"; do
    name="${entry%%|*}"
    flags="${entry#*|}"

    if [ -n "$ONLY" ] && [[ ",${ONLY}," != *",${name},"* ]]; then
        continue
    fi

    rates=()
    for run in $(seq 1 "$RUNS"); do
        # shellcheck disable=SC2086
        out=$("$BIN" --bench="$HASHES" --no-color $flags $THREADS 2>&1)
        rc=$?
        rate=$(printf '%s\n' "$out" | awk '/benchmark:/ { for (i = 1; i <= NF; ++i) if ($i == "=") { print $(i+1), $(i+2); exit } }')
        unit=$(printf '%s' "$rate" | awk '{ print $2 }')
        value=$(printf '%s' "$rate" | awk '{ print $1 }')
        if [ "$rc" -ne 0 ] || [ -z "$rate" ]; then
            # A config that does not even run is not a 0 H/s data point.
            printf '    %s: run %s failed (rc=%s)\n%s\n' "$name" "$run" "$rc" "$(printf '%s' "$out" | tail -3)" >&2
            rates+=("nan")
            continue
        fi
        case "$unit" in
            H/s)   ;;
            kH/s)  value=$(awk -v v="$value" 'BEGIN { printf "%.2f", v * 1000 }') ;;
            MH/s)  value=$(awk -v v="$value" 'BEGIN { printf "%.2f", v * 1000000 }') ;;
            *)     value=0 ;;
        esac
        rates+=("$value")
    done

    printf '%s\n' "${rates[@]}" > /tmp/zmrig-ab.$$
    if grep -q nan /tmp/zmrig-ab.$$; then
        rm -f /tmp/zmrig-ab.$$
        printf '%-18s %10s %10s %10s %10s\n' "$name" "FAILED" "-" "-" "-"
        continue
    fi
    med=$(median < /tmp/zmrig-ab.$$)
    min=$(sort -n /tmp/zmrig-ab.$$ | head -1)
    max=$(sort -n /tmp/zmrig-ab.$$ | tail -1)
    spread=$(awk -v a="$min" -v b="$max" -v m="$med" 'BEGIN { if (m > 0) printf "%.1f%%", (b - a) / m * 100; else printf "n/a" }')
    rm -f /tmp/zmrig-ab.$$

    printf '%-18s %10.2f %10.2f %10.2f %10s\n' "$name" "$med" "$min" "$max" "$spread"
done

printf '\nH/s, higher is better. Spread above ~3%% means the machine was not quiet\n'
printf 'enough for a conclusion; re-run before trusting a difference.\n'
