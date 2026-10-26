#!/usr/bin/env bash
#
# tune-linux.sh - prepare a Linux host for maximum RandomX hashrate.
#
# Everything this script changes is a runtime knob that the miner benefits from
# but cannot change itself (it would need root). Nothing is written to the GPU
# or to any persistent storage except the small sysfs/procfs values listed
# below, which the kernel resets on reboot.
#
# Usage:
#   sudo ./scripts/tune-linux.sh                # apply the recommended preset
#   sudo ./scripts/tune-linux.sh --dry-run      # show what would be changed
#   sudo ./scripts/tune-linux.sh --hugepages 1G # reserve 1GB pages instead of 2MB
#   ./scripts/tune-linux.sh --status            # read-only report (no root needed)
#
# Revert:
#   echo 0 | sudo tee /proc/sys/vm/nr_hugepages
#   echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
#
set -euo pipefail

HUGE_MODE="2M"          # 2M | 1G | off
THP_MODE="always"       # always | madvise | off
SWAPPINESS="10"
SET_GOVERNOR="performance"
DRY_RUN=0
STATUS_ONLY=0
QUIET=0

DATASET_MB=2080          # RandomX dataset (rx/0 family)
CACHE_MB=256             # RandomX cache

color() {
    if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}
info()  { [ "$QUIET" = 1 ] && return 0; printf ' * %s\n' "$*"; }
warn()  { printf ' ! %s\n' "$*"; }
ok()    { printf ' %s %s\n' "$(color '1;32' 'OK')" "$*"; }
step()  { [ "$QUIET" = 1 ] && return 0; printf '\n%s\n' "$(color '1;36' "$*")"; }

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY_RUN=1 ;;
        --status)         STATUS_ONLY=1 ;;
        --hugepages)      HUGE_MODE="${2:-2M}"; shift ;;
        --hugepages=*)    HUGE_MODE="${1#*=}" ;;
        --thp)            THP_MODE="${2:-always}"; shift ;;
        --thp=*)          THP_MODE="${1#*=}" ;;
        --swappiness)     SWAPPINESS="${2:-10}"; shift ;;
        --swappiness=*)   SWAPPINESS="${1#*=}" ;;
        --no-governor)    SET_GOVERNOR="" ;;
        -q|--quiet)       QUIET=1 ;;
        -h|--help)        usage ;;
        *)                warn "unknown option: $1"; usage ;;
    esac
    shift
done

read_meminfo() { awk -v k="$1" '$1 == k":" { print $2 }' /proc/meminfo; }

mem_total_mb=$(( $(read_meminfo MemTotal) / 1024 ))
cores=$(nproc)

# RandomX needs the dataset, the cache and one 2MB scratchpad per mining thread.
scratch_mb=$(( cores * 2 ))
required_mb=$(( DATASET_MB + CACHE_MB + scratch_mb + 128 ))   # + slack for the VM

show_status() {
    step "Current state"

    local hp_total hp_free hp_size
    hp_total=$(read_meminfo HugePages_Total)
    hp_free=$(read_meminfo HugePages_Free)
    hp_size=$(read_meminfo Hugepagesize)
    info "Hardware: ${cores} threads, ${mem_total_mb} MB RAM"

    if [ "${hp_total:-0}" -gt 0 ] 2>/dev/null; then
        ok "2MB huge pages: ${hp_free}/${hp_total} free (${hp_size} kB each)"
    else
        warn "2MB huge pages: none reserved (RandomX will run with 4KB pages -> up to 25% slower)"
    fi

    local one_g
    one_g=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
    if [ "${one_g:-0}" -gt 0 ] 2>/dev/null; then
        ok "1GB huge pages: ${one_g} reserved (best case for RandomX)"
    else
        info "1GB huge pages: not reserved (optional, needs ${DATASET_MB}MB+ of free contiguous RAM)"
    fi

    if [ -r /sys/kernel/mm/transparent_hugepage/enabled ]; then
        info "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
    fi

    if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        info "CPU governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    else
        info "CPU governor: not exposed by this kernel (VM or locked BIOS)"
    fi

    if [ -e /dev/cpu/0/msr ]; then
        ok "MSR access: /dev/cpu/0/msr available (rdmsr/wrmsr mod can be applied)"
    elif lsmod 2>/dev/null | grep -q '^msr '; then
        warn "MSR module loaded but /dev/cpu/0/msr missing"
    else
        warn "MSR access: module not loaded -> run this script as root to enable the MSR mod"
    fi

    info "RandomX memory budget for this host: ~${required_mb} MB"
}

if [ "$STATUS_ONLY" -eq 1 ]; then
    show_status
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    warn "this script must run as root to change kernel settings"
    show_status
    exit 1
fi

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would run: %s\n' "$*"
        return 0
    fi
    if "$@"; then return 0; fi
    warn "failed: $*"
    return 1
}

write_value() {
    local path="$1" value="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would write %s -> %s\n' "$value" "$path"
        return 0
    fi
    if printf '%s\n' "$value" > "$path" 2>/dev/null; then
        ok "$path = $value"
    else
        warn "cannot write $path (read-only or unsupported)"
    fi
}

# Same as write_value, but without the "OK" line: for values the kernel accepts
# and then silently clamps, the read-back below is the only honest report.
write_value_quiet() {
    local path="$1" value="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   would write %s -> %s\n' "$value" "$path"
        return 0
    fi
    printf '%s\n' "$value" > "$path" 2>/dev/null || warn "cannot write $path (read-only or unsupported)"
}

step "1. Huge pages"
# The kernel clamps nr_hugepages to what it can actually carve out, so a write
# that "succeeds" can still leave the miner on 4 KiB pages. Always read back.
verify_huge_pages() {
    local want="$1"
    [ "$DRY_RUN" -eq 1 ] && return 0
    local got
    got=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo 0)
    if [ "$got" -ge "$want" ]; then
        ok "verified: ${got} x 2MB pages reserved ($((got * 2)) MB)"
    elif [ "$got" -gt 0 ]; then
        warn "only ${got} of ${want} pages could be reserved ($((got * 2)) MB); the miner will report a partial fallback"
        warn "free memory or lower the reservation, then re-run"
    else
        warn "the kernel reserved 0 pages: the miner will fall back to 4 KiB pages and lose up to 25% hashrate"
        warn "this is common inside containers (read-only /proc/sys) - reserve on the host instead"
    fi
}

case "$HUGE_MODE" in
    2M)
        pages=$(( (required_mb + 1) / 2 ))
        info "reserving ${pages} x 2MB pages ($((pages * 2))MB > ${required_mb}MB needed)"
        write_value /proc/sys/vm/nr_hugepages "$pages"
        verify_huge_pages "$pages"
        ;;
    1G)
        if [ "$(read_meminfo Hugepagesize)" != "2048" ] && [ "$DRY_RUN" -eq 0 ]; then
            info "kernel default huge page size is not 2MB, continuing anyway"
        fi
        info "reserving 3 x 1GB pages (dataset + cache); needs ${DATASET_MB}MB+ free contiguous RAM"
        write_value_quiet /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 3

        # Same trap as the 2MB pool: the kernel accepts the write and keeps 0
        # when it cannot find a contiguous gigabyte. Read back and fall back to
        # the 2MB pool instead of leaving the miner without huge pages at all.
        if [ "$DRY_RUN" -eq 0 ]; then
            got_1g=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
            if [ "${got_1g:-0}" -ge 3 ]; then
                ok "verified: ${got_1g} x 1GB pages reserved"
            elif [ "${got_1g:-0}" -gt 0 ]; then
                warn "only ${got_1g} of 3 1GB pages could be reserved; falling back to 2MB pages"
                pages=$(( (required_mb + 1) / 2 ))
                write_value /proc/sys/vm/nr_hugepages "$pages"
                verify_huge_pages "$pages"
            else
                warn "the kernel reserved no 1GB pages (no contiguous 1GB block or 1GB pages unsupported)"
                info "falling back to 2MB pages, which give the same RandomX speed"
                pages=$(( (required_mb + 1) / 2 ))
                write_value /proc/sys/vm/nr_hugepages "$pages"
                verify_huge_pages "$pages"
            fi
        fi
        ;;
    off)
        info "skipping huge page reservation"
        ;;
    *)
        warn "unknown --hugepages value '$HUGE_MODE' (expected 2M, 1G or off)"
        ;;
esac

step "2. Transparent huge pages"
if [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
    write_value /sys/kernel/mm/transparent_hugepage/enabled "$THP_MODE"
    if [ -w /sys/kernel/mm/transparent_hugepage/defrag ]; then
        # "defer" keeps khugepaged from stalling mining threads with direct reclaim.
        write_value /sys/kernel/mm/transparent_hugepage/defrag defer
    fi
else
    warn "THP controls not writable, skipping"
fi

step "3. VM tunables"
write_value /proc/sys/vm/swappiness "$SWAPPINESS"
if [ -w /proc/sys/vm/compact_memory ]; then
    info "compacting memory so the 2MB reservations can be fulfilled"
    run sh -c 'echo 1 > /proc/sys/vm/compact_memory' || true
fi

step "4. CPU governor"
if [ -n "$SET_GOVERNOR" ] && [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -w "$gov" ] || continue
        write_value "$gov" "$SET_GOVERNOR"
    done
else
    info "governor control not available or disabled"
fi

step "5. MSR access"
if [ ! -e /dev/cpu/0/msr ]; then
    run modprobe msr || warn "modprobe msr failed (kernel module may be missing)"
fi
if [ -e /dev/cpu/0/msr ]; then
    ok "MSR device present, xmrig can apply the RandomX MSR preset"
else
    warn "no MSR device: RandomX will run without the memory latency fix"
fi

step "6. Transparent page sharing (optional, reduces latency variance)"
if [ -w /sys/kernel/mm/ksm/run ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
        printf '   KSM state: %s (leave disabled for mining)\n' "$(cat /sys/kernel/mm/ksm/run)"
    fi
fi

step "Summary"
show_status

cat <<'EOF'

Next steps:
  1. Run the miner as root (or with CAP_SYS_RAWIO + CAP_IPC_LOCK + CAP_SYS_NICE) so
     huge pages, MSR writes and thread priorities are applied:
         sudo zmrig -c /etc/xmrig-ocean/config.json --msr
  2. Verify what the miner actually got, without mining:
         zmrig -o POOL:PORT -u WALLET --check
     The memory line says "huge pages reserved" when the reservation worked,
     and the msr line says whether the device is readable.
  3. The startup log repeats it:
         "hash engine ready: ..., huge pages 2336 MB (explicit)"
     A "(THP fallback)" or "(partial)" suffix means the kernel did not hand out
     the 2 MiB pages, and the hashrate drops ~24 %.
  4. These settings are not persistent across reboots. To persist them, call this
     script from a systemd unit or /etc/rc.local.
EOF
