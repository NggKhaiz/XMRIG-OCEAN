#!/usr/bin/env bash
#
# Builds and runs the C API conformance test for the zmrig hash engine.
#
#   ./zmrig/tests/run.sh            # build engine if needed, then test
#   ./zmrig/tests/run.sh --quick    # light mode only (no 2 GiB dataset)
#
# The test checks the RandomX reference vectors this repository already trusts
# (tests/hash/main.cpp), pipelined hashing against one-shot hashing, and that
# the full-memory dataset produces the same hashes as the cache.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/../.." && pwd)
LIB="${ROOT}/zmrig/out/libxmorx.a"
BIN="${ROOT}/zmrig/out/api_test"
QUICK=0

for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        -h|--help) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 1 ;;
    esac
done

if [ ! -f "$LIB" ]; then
    echo "==> libxmorx.a not found, building it first"
    "${ROOT}/zmrig/build.sh" --no-zig
fi

echo "==> compiling the API test"
g++ -std=c++11 -O2 -pthread -I "${ROOT}/zmrig/capi" \
    "${ROOT}/zmrig/tests/api_test.cpp" "$LIB" -o "$BIN"

echo "==> running"
if [ "$QUICK" = 1 ]; then
    # api_test takes the same environment switch as the miner.
    ZMRIG_TEST_QUICK=1 "$BIN"
else
    "$BIN"
fi
