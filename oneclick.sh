#!/usr/bin/env bash
#
# oneclick.sh - build, tune, install and supervise this miner with one command.
#
#   curl -fsSL https://raw.githubusercontent.com/NggKhaiz/XMRIG-OCEAN/arena/918a7f95-xmrig-ocean/oneclick.sh | sudo bash -s -- --wallet 4...
#
#   sudo ./oneclick.sh                     # full install, asks for the wallet
#   sudo ./oneclick.sh --wallet 4... --yes  # fully unattended
#   ./oneclick.sh status                   # is it mining? at what hashrate?
#   ./oneclick.sh bench                    # reproducible hashrate measurement
#   ./oneclick.sh verify                   # prove the 0% fee
#
# Subcommands
#   install (default)  deps + build + tune + config + service + self-check
#   build              compile only
#   tune               huge pages, THP, governor, MSR (root)
#   config             (re)generate the config file
#   start|stop|restart|status|logs
#   bench              RandomX benchmark
#   verify             fee-free audit
#   update             git pull + rebuild + restart
#   uninstall          stop, remove service, binary and (optionally) the config
#
# Everything is idempotent: re-running does not duplicate services, does not
# overwrite an existing config unless --force is passed, and skips a rebuild
# when the binary is newer than the sources.
#
# Licensed under GPL-3.0.
#
set -euo pipefail

ONECLICK_VERSION="1.0"

SELF="${BASH_SOURCE[0]:-}"
REPO_URL="${MINER_REPO_URL:-https://github.com/NggKhaiz/XMRIG-OCEAN.git}"
REPO_BRANCH="${MINER_BRANCH:-arena/918a7f95-xmrig-ocean}"

PREFIX="${MINER_PREFIX:-/usr/local}"
CONFIG_DIR="${MINER_CONFIG_DIR:-/etc/xmrig-ocean}"
STATE_DIR="${MINER_STATE_DIR:-/var/lib/xmrig-ocean}"
SERVICE_NAME="xmrig-ocean"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TUNE_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}-tune.service"

BUILD_DIR_DEFAULT="${MINER_BUILD_DIR:-${PREFIX}/src/xmrig-ocean-build}"
WALLET=""
POOL="${MINER_POOL:-gulf.moneroocean.stream:10001}"
POOL_PASS="${MINER_PASS:-x}"
RIG_ID=""
ALGO=""
TLS="false"
CPU_HINT="100"
ASSUME_YES=0
FORCE_CONFIG=0
DO_TUNE=1
DO_SERVICE=1
DO_BUILD=1
ALL_BACKENDS=0
NO_COLOR=0

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-0}" = 0 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'
    C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_C=$'\033[1;36m'
else
    C_RESET=""; C_DIM=""; C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_C" "$C_RESET" "$C_B" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s%s%s %s\n' "$C_G" "OK" "$C_RESET" "$*"; }
warn() { printf '    %s%s%s %s\n' "$C_Y" "!!" "$C_RESET" "$*"; }
fail() { printf '    %s%s%s %s\n' "$C_R" "xx" "$C_RESET" "$*" >&2; }
die()  { fail "$*"; exit 1; }

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    [ -t 0 ] || return 0
    local answer
    read -r -p "    $1 [Y/n] " answer || true
    case "${answer:-y}" in
        [yY]|[yY][eE][sS]|"") return 0 ;;
        *) return 1 ;;
    esac
}

usage() {
    sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options
  --wallet ADDR          Monero/pool wallet or login (asked interactively if omitted)
  --pool HOST:PORT       pool endpoint            (default: gulf.moneroocean.stream:10001)
  --pass VALUE           pool password            (default: x)
  --rig-id NAME          rig identifier shown on the pool dashboard
  --algo NAME            force one algorithm instead of pool auto-selection
  --tls                  use TLS for the pool connection
  --cpu-hint N           max-threads-hint percentage (default: 100)
  --build-dir DIR        where to compile        (default: PREFIX/src/xmrig-ocean-build)
  --all-backends         also build OpenCL/CUDA support
  --no-tune              skip huge pages/MSR/governor tuning
  --no-service           install and configure, but do not create a service
  --no-build             reuse an existing binary (implies --build-dir must be built)
  --force                regenerate the config file even if it exists
  --yes                  never ask anything
  --prefix DIR           install prefix          (default: /usr/local)
  --no-color             plain output
  -h, --help             this text

Environment
  UV_INCLUDE_DIR / UV_LIBRARY   use a locally built libuv instead of the system one
  MINER_REPO_URL / MINER_BRANCH  where to clone the sources from when piped
EOF
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
COMMAND=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        install|build|tune|config|start|stop|restart|status|logs|bench|verify|update|uninstall)
            COMMAND="$1" ;;
        --wallet)        WALLET="${2:?}"; shift ;;
        --wallet=*)      WALLET="${1#*=}" ;;
        --pool)          POOL="${2:?}"; shift ;;
        --pool=*)        POOL="${1#*=}" ;;
        --pass)          POOL_PASS="${2:?}"; shift ;;
        --pass=*)        POOL_PASS="${1#*=}" ;;
        --rig-id)        RIG_ID="${2:?}"; shift ;;
        --rig-id=*)      RIG_ID="${1#*=}" ;;
        --algo)          ALGO="${2:?}"; shift ;;
        --algo=*)        ALGO="${1#*=}" ;;
        --tls)           TLS="true" ;;
        --cpu-hint)      CPU_HINT="${2:?}"; shift ;;
        --cpu-hint=*)    CPU_HINT="${1#*=}" ;;
        --build-dir)     BUILD_DIR_DEFAULT="${2:?}"; shift ;;
        --build-dir=*)   BUILD_DIR_DEFAULT="${1#*=}" ;;
        --prefix)        PREFIX="${2:?}"; shift ;;
        --prefix=*)      PREFIX="${1#*=}" ;;
        --all-backends)  ALL_BACKENDS=1 ;;
        --no-tune)       DO_TUNE=0 ;;
        --no-service)    DO_SERVICE=0 ;;
        --no-build)      DO_BUILD=0 ;;
        --force)         FORCE_CONFIG=1 ;;
        --yes|-y)        ASSUME_YES=1 ;;
        --no-color)      NO_COLOR=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               ARGS+=("$1") ;;
    esac
    shift
done

[ -n "$COMMAND" ] || COMMAND="install"

# ---------------------------------------------------------------------------
# environment detection
# ---------------------------------------------------------------------------
BIN_DIR="${PREFIX}/bin"
BINARY="${BIN_DIR}/xmrig-ocean"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BUILD_DIR="${BUILD_DIR_DEFAULT}"

have() { command -v "$1" >/dev/null 2>&1; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have sudo; then
        sudo -n "$@" 2>/dev/null || sudo "$@"
    else
        die "root is required for: $*"
    fi
}

is_root() { [ "$(id -u)" -eq 0 ]; }

has_systemd() {
    have systemctl && [ -d /run/systemd/system ]
}

detect_os() {
    OS_ID="unknown"; OS_LIKE=""; OS_VER=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
        OS_VER="${VERSION_ID:-}"
    elif have sw_vers; then
        OS_ID="macos"
    fi
}

CONFIGURED_ROOT=""
resolve_root() {
    if [ -n "$CONFIGURED_ROOT" ]; then
        return 0
    fi

    local candidate=""
    if [ -n "$SELF" ] && [ -f "$SELF" ]; then
        candidate=$(cd -- "$(dirname -- "$SELF")" && pwd)
    fi

    if [ -n "$candidate" ] && [ -f "${candidate}/CMakeLists.txt" ] && [ -d "${candidate}/src" ]; then
        CONFIGURED_ROOT="$candidate"
        return 0
    fi

    # Piped through curl/bash: fetch the sources once, then use them.
    local dest="${PREFIX}/src/xmrig-ocean"
    step "fetching sources"
    have git || die "git is required to fetch the sources. Install git first."
    if [ -d "${dest}/.git" ]; then
        info "reusing ${dest}"
        as_root git -C "$dest" fetch --depth 1 origin "$REPO_BRANCH" >/dev/null 2>&1 || true
        as_root git -C "$dest" checkout -q "$REPO_BRANCH" 2>/dev/null || true
    else
        as_root mkdir -p "$(dirname "$dest")"
        as_root git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$dest" || die "clone failed"
    fi
    CONFIGURED_ROOT="$dest"
    ok "sources: ${dest} (branch ${REPO_BRANCH})"
}

# ---------------------------------------------------------------------------
# dependencies
# ---------------------------------------------------------------------------
pkg_install() {
    local pkgs=("$@")
    if have apt-get; then
        as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    elif have dnf; then
        as_root dnf install -y -q "${pkgs[@]}"
    elif have yum; then
        as_root yum install -y -q "${pkgs[@]}"
    elif have pacman; then
        as_root pacman -Sy --noconfirm --needed "${pkgs[@]}"
    elif have zypper; then
        as_root zypper -q install -y "${pkgs[@]}"
    elif have apk; then
        as_root apk add --no-cache "${pkgs[@]}"
    elif have brew; then
        brew install "${pkgs[@]}"
    else
        return 1
    fi
}

ensure_deps() {
    step "checking build dependencies"

    local missing=()
    have cmake      || missing+=("cmake")
    have c++        || missing+=("g++")
    have make       || missing+=("make")
    have git        || missing+=("git")

    local need_uv=0
    if [ -n "${UV_INCLUDE_DIR:-}" ] && [ -n "${UV_LIBRARY:-}" ]; then
        info "using libuv from UV_INCLUDE_DIR/UV_LIBRARY"
    elif ! find_uv_header; then
        need_uv=1
    fi

    if [ ${#missing[@]} -gt 0 ] || [ "$need_uv" = 1 ]; then
        info "missing: ${missing[*]:-}${need_uv:+ libuv headers}"
        if confirm "install them with the system package manager?"; then
            case "$OS_ID" in
                debian|ubuntu|linuxmint|pop|raspbian|devuan|kali)
                    pkg_install build-essential cmake git libuv1-dev libssl-dev libhwloc-dev || true ;;
                fedora|rhel|centos|rocky|almalinux)
                    pkg_install gcc gcc-c++ make cmake git libuv-devel openssl-devel hwloc-devel || true ;;
                arch|manjaro|endeavouros)
                    pkg_install base-devel cmake git libuv openssl hwloc || true ;;
                alpine)
                    pkg_install build-base cmake git libuv-dev openssl-dev hwloc-dev || true ;;
                opensuse*|sles)
                    pkg_install gcc gcc-c++ make cmake git libuv-devel libopenssl-devel hwloc-devel || true ;;
                macos)
                    pkg_install cmake libuv openssl hwloc || true ;;
                *)
                    warn "unknown distribution '${OS_ID}', install cmake, a C++ compiler, git and libuv manually" ;;
            esac
        else
            die "cannot continue without the build dependencies"
        fi

        have cmake || die "cmake is still missing"
        have c++   || die "no C++ compiler found"
        if ! find_uv_header && [ -z "${UV_INCLUDE_DIR:-}" ]; then
            warn "libuv headers are still missing (uv.h)"
            info "Debian/Ubuntu: apt install libuv1-dev"
            info "or build libuv yourself and pass UV_INCLUDE_DIR=... UV_LIBRARY=..."
            die "libuv is required"
        fi
    fi

    ok "toolchain: $(c++ --version 2>/dev/null | head -1)"
    ok "cmake:     $(cmake --version | head -1)"
}

find_uv_header() {
    local d
    for d in /usr/include /usr/local/include /opt/homebrew/include /usr/include/x86_64-linux-gnu \
             /usr/include/aarch64-linux-gnu /usr/include/arm-linux-gnueabihf; do
        [ -f "${d}/uv.h" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
build_miner() {
    resolve_root
    step "building (Release, native ISA, CPU-optimised)"

    local args=(--build-dir "$BUILD_DIR" --jobs "$(nproc 2>/dev/null || echo 2)")
    [ "$ALL_BACKENDS" = 1 ] && args+=(--all-backends)

    if [ -f "${BUILD_DIR}/xmrig" ] && [ -z "${FORCE_REBUILD:-}" ]; then
        local newest
        newest=$(find "$CONFIGURED_ROOT/src" "$CONFIGURED_ROOT/cmake" -type f -newer "${BUILD_DIR}/xmrig" -print -quit 2>/dev/null || true)
        if [ -z "$newest" ]; then
            ok "binary is up to date: ${BUILD_DIR}/xmrig"
            return 0
        fi
        info "sources changed since the last build, rebuilding"
    fi

    as_root mkdir -p "$BUILD_DIR" 2>/dev/null || mkdir -p "$BUILD_DIR"

    # build-optimized.sh writes into an arbitrary directory; run it as the
    # invoking user when possible so the artifacts stay readable.
    if is_root; then
        "${CONFIGURED_ROOT}/scripts/build-optimized.sh" "${args[@]}"
    else
        sudo "${CONFIGURED_ROOT}/scripts/build-optimized.sh" "${args[@]}"
    fi

    [ -x "${BUILD_DIR}/xmrig" ] || die "build did not produce ${BUILD_DIR}/xmrig"
    ok "built $( "${BUILD_DIR}/xmrig" --version 2>/dev/null | head -1 )"
}

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
# The miner binary used for config validation and for bench/verify. The build
# directory varies between subcommands (install may have used --build-dir), so
# probe the usual locations instead of assuming one.
find_binary() {
    local candidate
    for candidate in "${BUILD_DIR}/xmrig" "${BUILD_DIR_DEFAULT}/xmrig" \
                     "${PREFIX}/src/xmrig-ocean-build/xmrig" "${BINARY}" \
                     "${CONFIGURED_ROOT:-.}/build/xmrig"; do
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

prompt_wallet() {
    [ -n "$WALLET" ] && return 0
    if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
        die "no --wallet given. Re-run with --wallet <address> or without --yes."
    fi
    printf '\n'
    info "Monero address (or pool login) to mine to:"
    read -r -p "    wallet: " WALLET || true
    [ -n "$WALLET" ] || die "wallet is required"
}

check_wallet() {
    local w="$1"
    case "${#w}" in
        95|106) ok "wallet length looks like a Monero address" ;;
        4|34|42|64) info "treating '${w}' as a pool login, not a raw Monero address" ;;
        *) warn "wallet/login is ${#w} characters; Monero addresses are 95 (or 106 integrated). Continuing." ;;
    esac
}

write_config() {
    prompt_wallet
    check_wallet "$WALLET"

    step "writing configuration"

    if [ -f "$CONFIG_FILE" ] && [ "$FORCE_CONFIG" != 1 ]; then
        ok "keeping existing ${CONFIG_FILE} (use --force to regenerate)"
        return 0
    fi

    as_root mkdir -p "$CONFIG_DIR"

    local rig="${RIG_ID:-$(hostname -s 2>/dev/null || echo rig)}"
    local algo_json="null"
    [ -n "$ALGO" ] && algo_json="\"${ALGO}\""

    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
{
    "api": {
        "id": null,
        "worker-id": "${rig}"
    },
    "http": {
        "enabled": true,
        "host": "127.0.0.1",
        "port": 18080,
        "access-token": null,
        "restricted": true
    },
    "autosave": true,
    "background": false,
    "colors": false,
    "title": true,
    "randomx": {
        "init": -1,
        "init-avx2": -1,
        "mode": "auto",
        "rdmsr": true,
        "wrmsr": true,
        "cache_qos": false,
        "numa": true,
        "scratchpad_prefetch_mode": 1
    },
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true,
        "hw-aes": null,
        "priority": 5,
        "memory-pool": true,
        "yield": false,
        "max-threads-hint": ${CPU_HINT},
        "asm": true,
        "argon2-impl": null,
        "cn/0": false,
        "cn-lite/0": false
    },
    "opencl": {
        "enabled": false,
        "cache": true,
        "loader": null,
        "platform": "AMD",
        "adl": true
    },
    "cuda": {
        "enabled": false,
        "loader": null,
        "nvml": true
    },
    "donate-level": 0,
    "log-file": null,
    "pools": [
        {
            "algo": ${algo_json},
            "coin": null,
            "url": "${POOL}",
            "user": "${WALLET}",
            "pass": "${POOL_PASS}",
            "rig-id": "${rig}",
            "nicehash": false,
            "keepalive": true,
            "enabled": true,
            "tls": ${TLS},
            "tls-fingerprint": null,
            "daemon": false,
            "socks5": null,
            "self-select": null,
            "submit-to-origin": false
        }
    ],
    "print-time": 60,
    "health-print-time": 60,
    "dmi": true,
    "retries": 5,
    "retry-pause": 5,
    "syslog": false,
    "tls": {
        "enabled": false,
        "protocols": null,
        "cert": null,
        "cert_key": null,
        "ciphers": null,
        "ciphersuites": null,
        "dhparam": null
    },
    "user-agent": null,
    "verbose": 0,
    "watch": true,
    "pause-on-battery": false,
    "pause-on-active": false,
    "bench-algo-time": 10,
    "algo-min-time": 20
}
EOF

    # Validate with the miner itself before installing it - a broken config
    # under systemd means a restart loop.
    local validator
    if validator=$(find_binary); then
        if ! "$validator" --dry-run -c "$tmp" >/tmp/xmrig-ocean-cfgcheck.$$ 2>&1; then
            warn "the miner rejected the generated config:"
            sed 's/\x1b\[[0-9;]*m//g' /tmp/xmrig-ocean-cfgcheck.$$ | tail -5
            rm -f "$tmp" /tmp/xmrig-ocean-cfgcheck.$$
            die "fix the wallet/pool arguments and try again"
        fi
        rm -f /tmp/xmrig-ocean-cfgcheck.$$
    else
        warn "no miner binary found to validate the config, writing it anyway"
    fi

    as_root install -m 0640 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
    ok "config: ${CONFIG_FILE}"
    info "pool:   ${POOL}$([ "$TLS" = true ] && echo ' (TLS)')"
    info "wallet: ${WALLET:0:12}...${WALLET: -6}"
}

# ---------------------------------------------------------------------------
# tuning
# ---------------------------------------------------------------------------
run_tune() {
    resolve_root
    step "tuning the host (huge pages, THP, governor, MSR)"
    if [ "$DO_TUNE" != 1 ]; then
        info "skipped (--no-tune)"
        return 0
    fi
    if is_root; then
        "${CONFIGURED_ROOT}/scripts/tune-linux.sh" || warn "tuning reported problems, continuing"
    elif have sudo; then
        sudo "${CONFIGURED_ROOT}/scripts/tune-linux.sh" || warn "tuning reported problems, continuing"
    else
        warn "not root, skipping host tuning"
    fi
}

# ---------------------------------------------------------------------------
# install + service
# ---------------------------------------------------------------------------
install_binary() {
    step "installing"
    as_root mkdir -p "$BIN_DIR" "$STATE_DIR"
    as_root install -m 0755 "${BUILD_DIR}/xmrig" "${BINARY}"
    ok "binary: ${BINARY}"

    if [ -f "${CONFIGURED_ROOT}/scripts/tune-linux.sh" ]; then
        as_root install -m 0755 "${CONFIGURED_ROOT}/scripts/tune-linux.sh" "${BIN_DIR}/xmrig-ocean-tune"
        as_root install -m 0755 "${CONFIGURED_ROOT}/scripts/bench.sh" "${BIN_DIR}/xmrig-ocean-bench"
        as_root install -m 0755 "${CONFIGURED_ROOT}/scripts/verify-fee-free.sh" "${BIN_DIR}/xmrig-ocean-verify"
        ok "helpers: xmrig-ocean-tune, xmrig-ocean-bench, xmrig-ocean-verify"
    fi
}

write_service() {
    [ "$DO_SERVICE" = 1 ] || { info "service not requested (--no-service)"; return 0; }

    if ! has_systemd; then
        warn "systemd not available here, starting the miner in the background instead"
        bg_start
        return 0
    fi

    step "installing the systemd service"

    if [ "$DO_TUNE" = 1 ]; then
    as_root tee "$TUNE_SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=XMRig Ocean host tuning (huge pages, THP, MSR)
Before=${SERVICE_NAME}.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${BIN_DIR}/xmrig-ocean-tune --quiet

[Install]
WantedBy=multi-user.target
EOF
    else
        as_root rm -f "$TUNE_SERVICE_FILE"
    fi

    as_root tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=XMRig Ocean - fee-free RandomX miner
Documentation=file://${CONFIGURED_ROOT}/README.md
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${BINARY} -c ${CONFIG_FILE} --no-color
WorkingDirectory=${STATE_DIR}
Restart=always
RestartSec=5
Nice=-10
LimitMEMLOCK=infinity
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
# The miner needs huge pages, /dev/cpu/*/msr and scheduling priority; the
# config directory must stay writable because autosave rewrites the file.
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${CONFIG_DIR} ${STATE_DIR}

[Install]
WantedBy=multi-user.target
EOF

    as_root systemctl daemon-reload
    if [ "$DO_TUNE" = 1 ]; then
        as_root systemctl enable --now "${SERVICE_NAME}-tune.service" >/dev/null 2>&1 || warn "tuning unit could not be started"
    fi
    as_root systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    ok "service installed: ${SERVICE_NAME}"
}

svc_ctl() {
    if has_systemd && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        as_root systemctl "$1" "${SERVICE_NAME}.service"
    else
        bg_ctl "$1"
    fi
}

PIDFILE="${STATE_DIR}/miner.pid"
LOGFILE="${STATE_DIR}/miner.log"

bg_start() {
    as_root mkdir -p "$STATE_DIR"
    if bg_running; then
        info "already running (pid $(cat "$PIDFILE" 2>/dev/null))"
        return 0
    fi
    as_root touch "$LOGFILE"
    # shellcheck disable=SC2024
    as_root nohup "$BINARY" -c "$CONFIG_FILE" --no-color >>"$LOGFILE" 2>&1 &
    echo $! | as_root tee "$PIDFILE" >/dev/null
    sleep 2
    if bg_running; then
        ok "started in the background (pid $(cat "$PIDFILE"))"
    else
        warn "process exited immediately, last log lines:"
        tail -5 "$LOGFILE" || true
    fi
}

bg_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

bg_ctl() {
    case "$1" in
        start)   bg_start ;;
        stop)    if bg_running; then as_root kill "$(cat "$PIDFILE")" && ok "stopped"; else info "not running"; fi ;;
        restart) bg_ctl stop; bg_start ;;
        status)  if bg_running; then echo "    running (pid $(cat "$PIDFILE"))"; else echo "    stopped"; fi ;;
    esac
}

# Current hashrate from the local HTTP API, falling back to the log tail.
current_hashrate() {
    local api
    if api=$(summary_hashrate 2>/dev/null) && [ -n "${api// /}" ]; then
        printf '%s' "$api"
        return 0
    fi

    local line
    line=$(log_tail 200 | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'speed 10s/60s/15m [^H]*' | tail -1 | sed 's/speed 10s\/60s\/15m //') || true
    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
}

log_tail() {
    local lines="${1:-40}"
    if has_systemd && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        as_root journalctl -u "${SERVICE_NAME}.service" -n "$lines" --no-pager 2>/dev/null || true
    elif [ -f "$LOGFILE" ]; then
        tail -n "$lines" "$LOGFILE" || true
    fi
}

# Same, but bounded in time. The journal keeps earlier runs of the unit name,
# so "does this run calibrate?" must not look at lines from an hour ago.
log_recent() {
    local minutes="${1:-5}"
    if has_systemd && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        as_root journalctl -u "${SERVICE_NAME}.service" --since "-${minutes} min" --no-pager 2>/dev/null || true
    elif [ -f "$LOGFILE" ]; then
        tail -n 200 "$LOGFILE" || true
    fi
}

wait_ready() {
    local timeout="${1:-180}"
    local waited=0
    local calibrating=0

    step "waiting for the first share"

    while [ "$waited" -lt "$timeout" ]; do
        local state
        state=$(service_state)
        if [ "$state" != "active" ] && ! bg_running; then
            fail "the miner stopped (state: ${state})"
            show_logs 20
            return 1
        fi

        local hr
        if hr=$(current_hashrate) && printf '%s' "$hr" | grep -qE '[1-9]'; then
            printf '\n'
            ok "hashing at ${hr} H/s (10s/60s/15m)"
            return 0
        fi

        # First start on MoneroOcean calibrates every algorithm (~10 s each)
        # before the pool picks one. That is expected, not a failure.
        if [ "$calibrating" = 0 ] && log_recent 5 | grep -q 'STARTING ALGO PERFORMANCE CALIBRATION'; then
            calibrating=1
            timeout=$((timeout + 240))
            printf '\n'
            info "calibrating algorithm performance (first start only, ~2 minutes)"
        fi

        printf '.'
        sleep 3
        waited=$((waited + 3))
    done

    printf '\n'
    if [ "$calibrating" = 1 ]; then
        warn "still calibrating; the miner will connect as soon as it finishes"
    else
        warn "no hashrate after ${timeout}s - the pool may be unreachable from this host"
    fi
    show_logs 20
    return 1
}

service_state() {
    if has_systemd && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true
    elif bg_running; then
        echo "active"
    else
        echo "inactive"
    fi
}

# Prints "10s 60s 15m" from the local API. The JSON is pretty printed, so this
# walks the "hashrate" object until it finds the "total" array.
summary_hashrate() {
    have curl || return 1
    curl -fsS --max-time 3 "http://127.0.0.1:18080/2/summary" 2>/dev/null \
        | awk '/"hashrate"/ { found = 1; next }
               found && /"total"/ {
                   sub(/^[^\[]*\[/, ""); sub(/\].*$/, "");
                   gsub(/,/, " "); gsub(/null/, "-");
                   n = split("10s 60s 15m", label, " ");
                   out = "";
                   for (i = 1; i <= n && i <= NF; i++) {
                       if ($i == "-") continue;
                       out = out (out == "" ? "" : " ") label[i] "=" $i;
                   }
                   print out; exit
               }'
}

# Accepted / total shares from the same API, empty when unavailable.
summary_shares() {
    have curl || return 1
    curl -fsS --max-time 3 "http://127.0.0.1:18080/2/summary" 2>/dev/null \
        | awk -F: '/"shares_good"/ { gsub(/[ ,]/, "", $2); good = $2 }
                   /"shares_total"/ { gsub(/[ ,]/, "", $2); total = $2 }
                   END { if (good != "") printf "%s/%s", good, total }'
}

show_logs() {
    local lines="${1:-40}"
    if has_systemd && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        as_root journalctl -u "${SERVICE_NAME}.service" -n "$lines" --no-pager 2>/dev/null || true
    elif [ -f "$LOGFILE" ]; then
        tail -n "$lines" "$LOGFILE" || true
    fi
}

# ---------------------------------------------------------------------------
# self check
# ---------------------------------------------------------------------------
self_check() {
    resolve_root
    step "self-check"

    [ -x "$BINARY" ] && ok "binary installed: $("$BINARY" --version 2>/dev/null | head -1)" || fail "binary missing"

    if [ -x "${CONFIGURED_ROOT}/scripts/verify-fee-free.sh" ]; then
        if "${CONFIGURED_ROOT}/scripts/verify-fee-free.sh" --binary "$BINARY" >/tmp/xmrig-ocean-verify.$$ 2>&1; then
            ok "fee audit: 0% developer fee"
        else
            warn "fee audit reported a problem:"
            tail -5 /tmp/xmrig-ocean-verify.$$ || true
        fi
        rm -f /tmp/xmrig-ocean-verify.$$
    fi

    if has_systemd && [ -f "$SERVICE_FILE" ]; then
        ok "service: $(service_state)"
    fi

    if [ -r /proc/meminfo ]; then
        local hp
        hp=$(awk '$1 == "HugePages_Total:" { print $2 }' /proc/meminfo 2>/dev/null || echo 0)
        if [ "${hp:-0}" -gt 0 ]; then
            ok "huge pages reserved: ${hp} x 2 MiB"
        else
            warn "no huge pages reserved yet (the tune service creates them at boot)"
        fi
    fi

    local hr
    local hr shares
    if hr=$(current_hashrate) && [ -n "$hr" ]; then
        ok "hashrate: ${hr} H/s"
    fi
    if shares=$(summary_shares 2>/dev/null) && [ -n "$shares" ]; then
        ok "shares accepted/total: ${shares}"
    fi
}

summary_card() {
    cat <<EOF

${C_G}${C_B}  XMRig Ocean is ready${C_RESET}

    binary    ${BINARY}
    config    ${CONFIG_FILE}
    service   ${SERVICE_NAME} ($(service_state))
    pool      ${POOL}
    wallet    ${WALLET:0:12}...${WALLET: -6}
    fee       0% (no donation code in this build)

    ${C_B}next${C_RESET}
      xmrig-ocean status      # or: ./oneclick.sh status
      xmrig-ocean logs        # or: journalctl -u ${SERVICE_NAME} -f
      xmrig-ocean-bench       # reproducible RandomX measurement
      xmrig-ocean-verify      # prove the 0% fee

EOF
}

# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------
cmd_install() {
    detect_os
    echo
    printf '%s\n' "${C_B}${C_C}  XMRig Ocean one-click installer ${ONECLICK_VERSION}${C_RESET}"
    printf '%s\n' "  ${C_DIM}$(uname -srm), ${OS_ID:-unknown} ${OS_VER}, $(nproc 2>/dev/null || echo '?') threads, $(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo '?') GiB RAM${C_RESET}"

    ensure_deps

    if [ "$DO_BUILD" = 1 ]; then
        build_miner
    else
        info "reusing ${BUILD_DIR}/xmrig"
        [ -x "${BUILD_DIR}/xmrig" ] || die "no binary in ${BUILD_DIR}"
    fi

    run_tune
    write_config
    install_binary
    write_service

    if [ "$DO_SERVICE" = 1 ]; then
        svc_ctl start >/dev/null 2>&1 || true
        wait_ready 90 || true
    fi

    self_check
    summary_card
}

cmd_update() {
    detect_os
    resolve_root
    step "updating sources"
    as_root git -C "$CONFIGURED_ROOT" fetch --all --quiet || die "git fetch failed"
    as_root git -C "$CONFIGURED_ROOT" checkout -q "$REPO_BRANCH" 2>/dev/null || true
    as_root git -C "$CONFIGURED_ROOT" pull --ff-only --quiet || warn "could not fast-forward"
    ok "sources at $(git -C "$CONFIGURED_ROOT" rev-parse --short HEAD)"

    FORCE_REBUILD=1 build_miner
    install_binary
    svc_ctl restart >/dev/null 2>&1 || true
    wait_ready 60 || true
    self_check
}

cmd_uninstall() {
    step "uninstalling"
    svc_ctl stop >/dev/null 2>&1 || true
    if has_systemd; then
        as_root systemctl disable "${SERVICE_NAME}.service" "${SERVICE_NAME}-tune.service" >/dev/null 2>&1 || true
        as_root rm -f "$SERVICE_FILE" "$TUNE_SERVICE_FILE"
        as_root systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    as_root rm -f "$BINARY" "${BIN_DIR}/xmrig-ocean-tune" "${BIN_DIR}/xmrig-ocean-bench" "${BIN_DIR}/xmrig-ocean-verify"
    ok "service and binaries removed"
    if [ "$FORCE_CONFIG" = 1 ]; then
        as_root rm -rf "$CONFIG_DIR"
        ok "config removed: ${CONFIG_DIR}"
    else
        info "config kept at ${CONFIG_FILE} (pass --force to delete it)"
    fi
    info "the build directory ${BUILD_DIR} was kept"
}

case "$COMMAND" in
    install)   cmd_install ;;
    build)     detect_os; ensure_deps; build_miner ;;
    tune)      detect_os; run_tune ;;
    config)    detect_os; resolve_root; write_config ;;
    start)     svc_ctl start; ok "start requested" ;;
    stop)      svc_ctl stop; ok "stop requested" ;;
    restart)   svc_ctl restart; ok "restart requested" ;;
    status)
        step "status"
        info "service:  $(service_state)"
        hr=$(current_hashrate 2>/dev/null || true)
        shares=$(summary_shares 2>/dev/null || true)
        if printf '%s' "$hr" | grep -qE '[1-9][0-9]*(\.| )'; then
            info "hashrate: ${hr} H/s (10s/60s/15m)"
        elif [ -n "$shares" ] && [ "${shares%%/*}" != "0" ]; then
            info "hashrate: warming up (measurement window restarted)"
        else
            info "hashrate: no data yet (calibrating, connecting, or idle)"
        fi
        if [ -f "$CONFIG_FILE" ]; then
            info "config:   ${CONFIG_FILE}"
        fi
        info "huge pages: $(awk '$1 == "HugePages_Total:" { print $2 }' /proc/meminfo 2>/dev/null || echo '?') x 2 MiB"
        shares=$(summary_shares 2>/dev/null || true)
        [ -n "$shares" ] && info "shares:   ${shares} accepted"
        show_logs 6
        ;;
    logs)      show_logs "${1:-40}" ;;
    bench)
        resolve_root
        binary=$(find_binary) || die "no binary found, run the installer first"

        # A running miner owns the reserved huge pages, so the benchmark would
        # measure a crippled dataset. Pause it, measure, bring it back.
        was_running=0
        if [ "$(service_state)" = "active" ]; then
            was_running=1
            info "pausing the miner so the benchmark gets the reserved huge pages"
            svc_ctl stop >/dev/null 2>&1 || true
            sleep 2
        fi

        rc=0
        "${CONFIGURED_ROOT}/scripts/bench.sh" --binary "$binary" "${ARGS[@]+"${ARGS[@]}"}" || rc=$?

        if [ "$was_running" = 1 ]; then
            svc_ctl start >/dev/null 2>&1 || true
            info "miner restarted"
        fi
        exit "$rc"
        ;;
    verify)
        resolve_root
        binary=$(find_binary) || die "no binary found, run the installer first"
        "${CONFIGURED_ROOT}/scripts/verify-fee-free.sh" --binary "$binary"
        ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall ;;
    *)         fail "unknown command: ${COMMAND}"; usage; exit 1 ;;
esac
