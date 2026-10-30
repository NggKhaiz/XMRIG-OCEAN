#!/usr/bin/env bash
#
# plan.sh - the zero-flag auto rules, asserted instead of asserted-about.
#
# `oneclick.sh plan` resolves every automatic decision and prints it without
# touching the machine, which makes the two rules that decide whether the
# install is any good testable:
#
#   engine  - a pool that switches algorithms needs the C++ engine; a plain
#             Monero pool can only send rx/0, where zmrig is faster and 0% fee
#   profile - free (watts do not matter) unless the user says otherwise
#
#   ./tests/oneclick/plan.sh
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { printf ' PASS %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAILED=1; }

# A fresh config directory per call: a recorded engine file from one case must
# not decide the next case (that would make the test pass for the wrong reason).
plan() {
    local dir="${PLAN_CFG:-$(mktemp -d "${WORK}/cfg.XXXXXX")}"
    mkdir -p "$dir"
    MINER_CONFIG_DIR="$dir" MINER_PREFIX="${WORK}/prefix" \
        bash "$ROOT/oneclick.sh" plan "$@" 2>&1
}

engine_of() { printf '%s\n' "$1" | sed -n 's/^ *engine *\([a-z]*\).*/\1/p' | head -1; }
# First word of a two-column line, e.g. "profile  watt  (requested)" -> "watt".
field_of()  { printf '%s\n' "$1" | sed -n "s/^ *$2 *\([a-z]*\).*/\1/p" | head -1; }

# --- engine follows the pool -------------------------------------------
# A switching pool now keeps the fee-free engine: zmrig advertises the RandomX
# family at login, so the pool can still pick the best-paying variant. The C++
# engine was only ever chosen here because zmrig could not negotiate.
out=$(plan --pool=gulf.moneroocean.stream:10001)
if [ "$(engine_of "$out")" = "zmrig" ]; then
    pass "a switching pool (moneroocean) keeps the fee-free engine"
else
    fail "moneroocean should resolve to zmrig, got '$(engine_of "$out")'"
fi

if printf '%s' "$out" | grep -q "advertises the RandomX family"; then
    pass "the reason is printed"
else
    fail "the engine decision has no printed reason"
fi

# The plan has to name the list, or the pool still sees a Monero-only rig.
if printf '%s' "$out" | grep -q "algo *auto"; then
    pass "a switching pool plans algo=auto"
else
    fail "the plan does not advertise the family"
fi

# An explicit pin still wins over auto.
out=$(plan --pool=gulf.moneroocean.stream:10001 --algo=rx/wow)
if printf '%s' "$out" | grep -q "algo *rx/wow"; then
    pass "an explicit --algo still pins"
else
    fail "--algo=rx/wow was replaced by auto"
fi

out=$(plan --pool=supportxmr.com:3333)
if [ "$(engine_of "$out")" = "zmrig" ]; then
    pass "a RandomX-only pool gets zmrig"
else
    fail "supportxmr should resolve to zmrig, got '$(engine_of "$out")'"
fi

out=$(plan --pool=pool.supportxmr.com:3333 --algo=cn/2)
if [ "$(engine_of "$out")" = "xmrig" ]; then
    pass "a non-RandomX algo overrides the pool rule"
else
    fail "cn/2 on a RandomX pool should force xmrig, got '$(engine_of "$out")'"
fi

out=$(plan --pool=supportxmr.com:3333 --engine=xmrig)
if [ "$(engine_of "$out")" = "xmrig" ]; then
    pass "an explicit --engine wins over the auto rule"
else
    fail "--engine=xmrig was overridden, got '$(engine_of "$out")'"
fi

# A previous install remembers its engine even when the user passes no pool.
mkdir -p "${WORK}/remembered"
printf 'zmrig\n' > "${WORK}/remembered/engine"
out=$(PLAN_CFG="${WORK}/remembered" plan --pool=supportxmr.com:3333 --profile=watt)
if [ "$(engine_of "$out")" = "zmrig" ]; then
    pass "a recorded engine is used on re-runs"
else
    fail "the recorded engine was ignored"
fi

# --- profile ------------------------------------------------------------
out=$(plan --profile=watt)
if [ "$(field_of "$out" "profile")" = "watt" ]; then
    pass "--profile=watt is honoured"
else
    fail "--profile=watt was not honoured: '$(field_of "$out" profile)'"
fi

# `pipefail` would make this pipeline fail on the rejection itself, so the
# output is captured first and grepped second.
out=$(plan --profile=bogus 2>&1)
if printf '%s' "$out" | grep -q "must be auto, free or watt"; then
    pass "an invalid profile is rejected with the three valid names"
else
    fail "an invalid profile was not rejected"
fi

# On this test machine (a container or a desktop) auto must resolve to free;
# a laptop on battery would resolve to watt, which is also a pass.
auto_profile=$(field_of "$(plan)" "profile")
case "$auto_profile" in
    free|watt) pass "auto resolves to a concrete profile (${auto_profile})" ;;
    *)         fail "auto did not resolve, got '${auto_profile}'" ;;
esac

# --- autotune is planned only where it applies -------------------------
out=$(plan --pool=supportxmr.com:3333)
if printf '%s' "$out" | grep -q "winner written to config.json"; then
    pass "zmrig plans a thread search"
else
    fail "zmrig did not plan a thread search"
fi

out=$(plan --pool=supportxmr.com:3333 --algo=cn/2)
if printf '%s' "$out" | grep -q "not applicable"; then
    pass "the C++ engine does not plan a thread search"
else
    fail "the C++ engine planned a thread search it cannot run"
fi

out=$(plan --pool=supportxmr.com:3333 --no-autotune)
if printf '%s' "$out" | grep -q "off, keeping the built-in heuristic"; then
    pass "--no-autotune is respected"
else
    fail "--no-autotune was ignored"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "plan: all checks passed"
    exit 0
fi

echo "plan: FAILED"
exit 1
