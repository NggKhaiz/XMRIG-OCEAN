#!/usr/bin/env bash
#
# oneclick.sh - build, tune, install and supervise this miner with one command.
#
#   curl -fsSL https://raw.githubusercontent.com/NggKhaiz/ZMRIG/BETA/oneclick.sh | sudo bash -s -- --wallet 4...
#
#   sudo ./oneclick.sh                     # full install, asks for the wallet
#   sudo ./oneclick.sh --wallet 4... --yes  # fully unattended
#   sudo ./oneclick.sh --wallet 4... --engine zmrig --cloudflare --ws-path /pool
#                                          # mine through a CDN / HTTPS-only egress
#   ./oneclick.sh status                   # is it mining? at what hashrate?
#   ./oneclick.sh bench                    # reproducible hashrate measurement
#   ./oneclick.sh report                   # machine report code for the web dashboard
#   ./oneclick.sh verify                   # prove the 0% fee
#
# Subcommands
#   install (default)  deps + build + tune + config + service + self-check
#   build              compile only
#   tune               huge pages, THP, governor, MSR (root)
#   config             (re)generate the config file
#   start|stop|restart|status|logs
#   bench              RandomX benchmark
#   report             machine report code (hashrate + power + shares)
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

ONECLICK_VERSION="1.2"
ZIG_VERSION="${MINER_ZIG_VERSION:-0.13.0}"

SELF="${BASH_SOURCE[0]:-}"
REPO_URL="${MINER_REPO_URL:-https://github.com/NggKhaiz/ZMRIG.git}"
REPO_BRANCH="${MINER_BRANCH:-BETA}"

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
ENGINE="${MINER_ENGINE:-xmrig}"
# Set when the engine was named by the user, so a stale install marker does not
# silently override the choice.
ENGINE_EXPLICIT="${MINER_ENGINE:+1}"
TLS="false"
# Restrictive-network options (zmrig only; they end up in the pool section of
# config.json, which the C++ engine ignores and zmrig understands).
NET_CLOUDFLARE=0
NET_CF_HOST=""
NET_CF_PORT=""
NET_TRANSPORT=""
NET_WS_PATH=""
NET_WS_ORIGIN=""
NET_PROXY=""
NET_CONNECT_TO=""
NET_TLS_CA=""
NET_IDLE_TIMEOUT=""
NET_KEEPALIVE_INTERVAL=""
# MSR / NiceHash / affinity for the zmrig engine. "auto" keeps the XMRig
# default (write the preset, restore on exit); "off" leaves the registers be.
MSR_MODE="auto"
CPU_AFFINITY=""
NICEHASH=0
# Machine report for the web dashboard (zmrig only): a small file the miner
# keeps up to date, so `cat` gives a code to paste into the calculator.
NET_REPORT=1
NET_REPORT_FILE=""
NET_POWER=""
# Local read-only monitoring API (XMRig-compatible JSON on 127.0.0.1:18080).
# `status` reads it, so it is on by default; --no-http turns it off.
NET_HTTP=1
NET_HTTP_PORT=18080
NET_HTTP_TOKEN=""
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
  --engine NAME          xmrig (default, all algorithms) or zmrig (Zig rewrite, rx/* only)
  --tls                  use TLS for the pool connection
  --cloudflare[=HOST[:PORT]]  WebSocket+TLS on 443 (works through CDNs and
                         firewalls that only allow HTTPS). Switches to the
                         zmrig engine, which is the only one that speaks it
  --transport KIND       tcp | tls | ws | wss, override the scheme in --pool
  --ws-path PATH         WebSocket path for --cloudflare (default: /)
  --ws-origin URL        Origin header for the WebSocket upgrade
  --proxy URL            http://user:pass@host:port or socks5://host:port
  --connect-to HOST:PORT dial this address but keep the pool name for SNI/Host
  --tls-ca FILE          trust the certificates in FILE (private CA / pinning)
  --idle-timeout N       reconnect if the pool is silent for N seconds (0 = never)
  --power W              wall power of this machine, written into the report code
                         (also used by the 'report' subcommand)
  --report-file PATH     where zmrig keeps its report code
                         (default: <state dir>/report.txt, zmrig only)
  --no-report            do not write a report file
  --http-port PORT       local monitoring API port   (default: 18080)
  --http-token TOKEN     require "Authorization: Bearer TOKEN" on the API
  --no-http              disable the local monitoring API entirely
  --cpu-hint N           max-threads-hint percentage (default: 100)
  --cpu-affinity MASK    mine only on these CPUs, XMRig bitmask (e.g. 0x3)
  --msr                  write the RandomX MSR preset (root, bare metal)
  --no-msr               never touch the MSR registers (containers, some VMs)
  --nicehash             mask the nonce for a NiceHash/rental pool
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
                                (default branch: BETA; ALPHA has the newest work)
EOF
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
COMMAND=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        install|build|tune|config|start|stop|restart|status|logs|bench|report|verify|update|uninstall)
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
        --engine)        ENGINE="${2:?}"; ENGINE_EXPLICIT=1; shift ;;
        --engine=*)      ENGINE="${1#*=}"; ENGINE_EXPLICIT=1 ;;
        --tls)           TLS="true" ;;
        --cloudflare)    NET_CLOUDFLARE=1 ;;
        --cloudflare=*)  NET_CLOUDFLARE=1
                         CF_VALUE="${1#*=}"
                         case "$CF_VALUE" in
                             *:*) NET_CF_HOST="${CF_VALUE%%:*}"; NET_CF_PORT="${CF_VALUE##*:}" ;;
                             "")  ;;
                             *)   NET_CF_HOST="$CF_VALUE" ;;
                         esac ;;
        --transport)     NET_TRANSPORT="${2:?}"; shift ;;
        --transport=*)   NET_TRANSPORT="${1#*=}" ;;
        --ws-path)       NET_WS_PATH="${2:?}"; shift ;;
        --ws-path=*)     NET_WS_PATH="${1#*=}" ;;
        --ws-origin)     NET_WS_ORIGIN="${2:?}"; shift ;;
        --ws-origin=*)   NET_WS_ORIGIN="${1#*=}" ;;
        --proxy)         NET_PROXY="${2:?}"; shift ;;
        --proxy=*)       NET_PROXY="${1#*=}" ;;
        --connect-to)    NET_CONNECT_TO="${2:?}"; shift ;;
        --connect-to=*)  NET_CONNECT_TO="${1#*=}" ;;
        --tls-ca)        NET_TLS_CA="${2:?}"; shift ;;
        --tls-ca=*)      NET_TLS_CA="${1#*=}" ;;
        --idle-timeout)  NET_IDLE_TIMEOUT="${2:?}"; shift ;;
        --idle-timeout=*) NET_IDLE_TIMEOUT="${1#*=}" ;;
        --http-port)     NET_HTTP_PORT="${2:?}"; shift ;;
        --http-port=*)   NET_HTTP_PORT="${1#*=}" ;;
        --http-token)    NET_HTTP_TOKEN="${2:?}"; shift ;;
        --http-token=*)  NET_HTTP_TOKEN="${1#*=}" ;;
        --no-http)       NET_HTTP=0 ;;
        --power)         NET_POWER="${2:?}"; shift ;;
        --power=*)       NET_POWER="${1#*=}" ;;
        --report-file)   NET_REPORT_FILE="${2:?}"; shift ;;
        --report-file=*) NET_REPORT_FILE="${1#*=}" ;;
        --no-report)     NET_REPORT=0 ;;
        --cpu-hint)      CPU_HINT="${2:?}"; shift ;;
        --cpu-hint=*)    CPU_HINT="${1#*=}" ;;
        --cpu-affinity)  CPU_AFFINITY="${2:?}"; shift ;;
        --cpu-affinity=*) CPU_AFFINITY="${1#*=}" ;;
        --msr)           MSR_MODE="on" ;;
        --no-msr)        MSR_MODE="off" ;;
        --nicehash)      NICEHASH=1 ;;
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

# The C++ engine has no WebSocket client, so any WebSocket transport means the
# Zig front end. Fail loudly instead of writing a config nothing can use.
if [ "$NET_CLOUDFLARE" = 1 ] || [ "$NET_TRANSPORT" = ws ] || [ "$NET_TRANSPORT" = wss ]; then
    case "$ENGINE" in
        zmrig) ;;
        *)
            if [ "$ENGINE_EXPLICIT" = 1 ] && [ "$ENGINE" != zmrig ]; then
                printf '\n%s!!%s %s\n' "${C_Y:-}" "${C_RESET:-}" "this transport needs the zmrig engine (the C++ miner has no WebSocket support); re-run without --engine $ENGINE" >&2
                exit 1
            fi
            ENGINE="zmrig"
            ENGINE_EXPLICIT=1
            ;;
    esac
fi

if [ -n "$NET_PROXY" ] || [ -n "$NET_CONNECT_TO" ] || [ -n "$NET_TLS_CA" ]; then
    if [ "$ENGINE" != zmrig ]; then
        printf '\n%s!!%s %s\n' "${C_Y:-}" "${C_RESET:-}" "--proxy/--connect-to/--tls-ca are implemented by zmrig; add --engine zmrig" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# environment detection
# ---------------------------------------------------------------------------
BIN_DIR="${PREFIX}/bin"
BINARY="${BIN_DIR}/xmrig-ocean"
# The engine decides which frontend gets installed and started:
#   xmrig - the C++ miner, all 34 algorithms (default)
#   zmrig - the Zig rewrite in zmrig/, RandomX family only
ENGINE_BINARY=""
CONFIG_FILE="${CONFIG_DIR}/config.json"
BUILD_DIR="${BUILD_DIR_DEFAULT}"

have() { command -v "$1" >/dev/null 2>&1; }

# sudo sanitises the environment by default, but `sudo -E` (or sudoers env_keep)
# can leak a stale D-Bus session address, which makes every systemctl call fail
# with "Failed to connect to bus". Strip those variables explicitly.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR "$@"
    elif have sudo; then
        sudo -n env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR "$@" 2>/dev/null \
            || sudo env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR "$@"
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
        fetch_branch "$dest"

        # A checkout that quietly fails leaves the tree on whatever branch it
        # was on last time -- the installer would then build the wrong sources
        # while reporting success. Say which branch is missing instead.
        checkout_branch "$dest"
    else
        as_root mkdir -p "$(dirname "$dest")"
        as_root git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$dest" || die "clone failed"
    fi
    CONFIGURED_ROOT="$dest"
    ok "sources: ${dest} (branch ${REPO_BRANCH})"
}

# Fetch exactly the branch we are about to check out.
#
# `git fetch --all` on a single-branch --depth 1 clone does not update the refs
# we need, and the old code hid the failure behind `|| true`, so `update` could
# fast-forward nothing and still print a new commit hash from the stale tree.
fetch_branch() {
    local repo="$1"

    # A branch named BETA is not necessarily tracked in a shallow clone made
    # from a different branch: fetch it by name into a real ref.
    as_root git -C "$repo" fetch --depth 1 origin "${REPO_BRANCH}:refs/remotes/origin/${REPO_BRANCH}" >/dev/null 2>&1 \
        || as_root git -C "$repo" fetch origin "${REPO_BRANCH}" >/dev/null 2>&1 \
        || die "cannot fetch branch ${REPO_BRANCH} from ${REPO_URL}; check the name and your network"
}

# Switch to REPO_BRANCH, creating the local branch if this clone does not have
# it yet.
#
# A --depth 1 single-branch clone only maps the one branch it was made from, so
# `git checkout ALPHA` fails there even after the ref has been fetched ("not a
# branch": the fetch refspec does not cover it). The explicit start point is
# what makes switching to another branch work, and --no-track keeps git from
# failing on the upstream that the refspec cannot express.
checkout_branch() {
    local repo="$1"

    if as_root git -C "$repo" rev-parse --verify --quiet "refs/heads/${REPO_BRANCH}" >/dev/null; then
        as_root git -C "$repo" checkout -q "${REPO_BRANCH}" 2>/dev/null \
            || die "cannot switch ${repo} to ${REPO_BRANCH}: uncommitted changes? (git -C ${repo} status)"
    else
        as_root git -C "$repo" checkout -q --no-track -b "${REPO_BRANCH}" "refs/remotes/origin/${REPO_BRANCH}" 2>/dev/null \
            || die "cannot create local branch ${REPO_BRANCH} in ${repo}; is the remote ref there?"
    fi
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

    resolve_engine

    # zmrig compiles the RandomX engine directly and needs no libuv, OpenSSL,
    # hwloc or cmake - only a C++ compiler, ar and zig (installed below).
    if [ "$ENGINE" = "zmrig" ]; then
        have g++ || die "g++ is required to build the zmrig hash engine"
        have ar  || die "ar (binutils) is required to build the zmrig hash engine"
        ok "toolchain: $(c++ --version 2>/dev/null | head -1)"
        return 0
    fi

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
# engine selection
# ---------------------------------------------------------------------------
# Picks the miner frontend. zmrig only speaks the RandomX family, so it always
# pins the algorithm: advertising more than that would get jobs it cannot hash.
resolve_engine() {
    # A previous install records which frontend is in place.
    if [ -z "${ENGINE_EXPLICIT:-}" ] && [ -f "${CONFIG_DIR}/engine" ]; then
        ENGINE=$(cat "${CONFIG_DIR}/engine" 2>/dev/null || echo xmrig)
    fi

    case "$ENGINE" in
        xmrig)
            ;;
        zmrig)
            if [ -z "$ALGO" ]; then
                ALGO="rx/0"
                info "zmrig mines the RandomX family only, pinning --algo rx/0"
            fi
            ;;
        *)
            die "unknown engine '${ENGINE}' (use xmrig or zmrig)"
            ;;
    esac

    case "$ALGO" in
        ""|rx|rx/0|randomx) ;;
        rx/*|panthera) ;;
        *)
            if [ "$ENGINE" = "zmrig" ]; then
                die "zmrig cannot mine ${ALGO}: it implements the RandomX family only (rx/0, rx/2, rx/wow, ...)"
            fi
            ;;
    esac

    # One installed binary per engine, so switching back and forth keeps both.
    if [ "$ENGINE" = "zmrig" ]; then
        ENGINE_BINARY="${BIN_DIR}/zmrig"
    else
        ENGINE_BINARY="${BIN_DIR}/xmrig-ocean"
    fi
}

# zig is not packaged by every distro, so fall back to the PyPI wheel which
# ships a complete static compiler.
ensure_zig() {
    if have zig; then
        ZIG_BIN=$(command -v zig)
        ok "zig: $("$ZIG_BIN" version)"
        return 0
    fi

    step "installing the Zig compiler"
    if have pip3 || have pip; then
        local pip="pip3"
        have pip3 || pip="pip"

        if as_root "$pip" install --break-system-packages --quiet "ziglang==${ZIG_VERSION}" 2>/dev/null \
           || as_root "$pip" install --quiet "ziglang==${ZIG_VERSION}" 2>/dev/null; then
            local zig_path
            zig_path=$(as_root "$pip" show -f ziglang 2>/dev/null | awk '/Location:/ { print $2 }')
            if [ -n "$zig_path" ] && [ -x "${zig_path}/ziglang/zig" ]; then
                as_root ln -sf "${zig_path}/ziglang/zig" "${BIN_DIR}/zig"
                ZIG_BIN="${zig_path}/ziglang/zig"
                ok "zig ${ZIG_VERSION} installed"
                return 0
            fi
        fi
    fi

    die "zig is required to build zmrig. Install it (https://ziglang.org/download) or use --engine xmrig"
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
build_miner() {
    resolve_root
    resolve_engine

    if [ "$ENGINE" = "zmrig" ]; then
        build_zmrig
        return 0
    fi

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

# zmrig = Zig frontend + the RandomX engine from this repository. The engine is
# compiled by zmrig/build.sh with the system C++ compiler, the miner by zig.
build_zmrig() {
    step "building zmrig (Zig frontend + RandomX JIT engine)"

    [ -d "${CONFIGURED_ROOT}/zmrig" ] || die "zmrig sources missing in ${CONFIGURED_ROOT}"
    ensure_zig

    if [ -x "${BUILD_DIR}/zmrig" ] && [ -z "${FORCE_REBUILD:-}" ]; then
        local newest
        newest=$(find "${CONFIGURED_ROOT}/zmrig" "${CONFIGURED_ROOT}/src/crypto/randomx" \
                      -type f -newer "${BUILD_DIR}/zmrig" -print -quit 2>/dev/null || true)
        if [ -z "$newest" ]; then
            ok "binary is up to date: ${BUILD_DIR}/zmrig"
            return 0
        fi
        info "sources changed since the last build, rebuilding"
    fi

    as_root mkdir -p "$BUILD_DIR"

    local jobs
    jobs=$(nproc 2>/dev/null || echo 2)

    ZIG="$ZIG_BIN" "${CONFIGURED_ROOT}/zmrig/build.sh" --jobs "$jobs" --output "${BUILD_DIR}"

    [ -x "${BUILD_DIR}/zmrig" ] || die "build did not produce ${BUILD_DIR}/zmrig"
    ok "built $( "${BUILD_DIR}/zmrig" --version 2>/dev/null | head -1 )"
}

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
# The miner binary used for config validation and for bench/verify. The build
# directory varies between subcommands (install may have used --build-dir), so
# probe the usual locations instead of assuming one.
find_binary() {
    local name="xmrig"
    [ "${ENGINE:-xmrig}" = "zmrig" ] && name="zmrig"

    local candidate
    for candidate in "${BUILD_DIR}/${name}" "${BUILD_DIR_DEFAULT}/${name}" \
                     "${PREFIX}/src/xmrig-ocean-build/${name}" "${ENGINE_BINARY}" \
                     "${BINARY}" "${CONFIGURED_ROOT:-.}/build/${name}" \
                     "${CONFIGURED_ROOT:-.}/zmrig/out/zmrig"; do
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

    # Restrictive-network presets. Everything lands in the pool section, which
    # zmrig reads and the C++ engine ignores.
    local pool_url="$POOL"
    local tls_flag="$TLS"
    if [ "$NET_CLOUDFLARE" = 1 ]; then
        local cf_host="${NET_CF_HOST:-${POOL%%:*}}"
        local cf_port=443
        # A port the user typed in --pool wins over the 443 preset; the preset
        # only fills in what was not specified.
        if [ -n "$NET_CF_PORT" ]; then
            cf_port="$NET_CF_PORT"
        elif [ -z "$NET_CF_HOST" ]; then
            case "$POOL" in
                *:*:*) ;;                      # IPv6 literal, keep 443
                *:*)   cf_port="${POOL##*:}" ;;
            esac
        fi
        local cf_path="${NET_WS_PATH:-/}"
        case "$cf_path" in /*) ;; *) cf_path="/${cf_path}" ;; esac
        pool_url="wss://${cf_host}:${cf_port}${cf_path}"
        tls_flag="true"
    elif [ -n "$NET_TRANSPORT" ] && [ "$NET_TRANSPORT" != tcp ]; then
        local t_host="${POOL%%:*}" t_port="${POOL##*:}"
        [ "$t_port" = "$t_host" ] && t_port=443
        case "$NET_TRANSPORT" in
            tls) pool_url="stratum+ssl://${t_host}:${t_port}"; tls_flag="true" ;;
            ws)  pool_url="ws://${t_host}:${t_port}${NET_WS_PATH:-/}" ;;
            wss) pool_url="wss://${t_host}:${t_port}${NET_WS_PATH:-/}"; tls_flag="true" ;;
        esac
    fi

    # A CA file has to survive for the lifetime of the service: /tmp is
    # private to the unit (PrivateTmp) and often wiped at boot, so keep our own
    # copy next to the config and point the pool there.
    local tls_ca_path=""
    if [ -n "$NET_TLS_CA" ]; then
        if [ -r "$NET_TLS_CA" ]; then
            as_root mkdir -p "$CONFIG_DIR"
            as_root install -m 0644 "$NET_TLS_CA" "${CONFIG_DIR}/tls-ca.pem" \
                && tls_ca_path="${CONFIG_DIR}/tls-ca.pem" \
                || warn "cannot copy ${NET_TLS_CA}, using it in place"
        else
            warn "cannot read the CA file ${NET_TLS_CA}"
        fi
        [ -n "$tls_ca_path" ] || tls_ca_path="$NET_TLS_CA"
    fi

    # JSON booleans, not shell integers: XMRig's parser (and ours) reads a
    # boolean here, and `enabled: 1` would be silently ignored.
    local http_enabled="true"
    [ "$NET_HTTP" = "1" ] || http_enabled="false"

    # `access-token` is a JSON string or null; quote it only when it is set.
    local http_token="null"
    [ -n "$NET_HTTP_TOKEN" ] && http_token="\"${NET_HTTP_TOKEN}\""

    # zmrig keys (the C++ engine ignores them). MSR is on by default here: the
    # service runs as root and the miner restores the old values on exit.
    local msr_flag="true"
    [ "$MSR_MODE" = "off" ] && msr_flag="false"

    local nicehash_flag="false"
    [ "$NICEHASH" = 1 ] && nicehash_flag="true"

    # JSON has no hex literals: convert the bitmask to a decimal number.
    local affinity_json="null"
    if [ -n "$CPU_AFFINITY" ]; then
        case "$CPU_AFFINITY" in
            ''|*[!0-9a-fA-FxX]*) die "--cpu-affinity needs a bitmask like 0x3" ;;
            0x*|0X*) affinity_json=$((CPU_AFFINITY)) ;;
            *)       affinity_json="$CPU_AFFINITY" ;;
        esac
    fi

    local extra_pool=""
    [ -n "$NET_TRANSPORT" ] && extra_pool="${extra_pool},
            \"transport\": \"${NET_TRANSPORT}\""
    [ -n "$NET_WS_PATH" ] && extra_pool="${extra_pool},
            \"ws-path\": \"${NET_WS_PATH}\""
    [ -n "$NET_WS_ORIGIN" ] && extra_pool="${extra_pool},
            \"ws-origin\": \"${NET_WS_ORIGIN}\""
    [ -n "$NET_PROXY" ] && extra_pool="${extra_pool},
            \"proxy\": \"${NET_PROXY}\""
    [ -n "$NET_CONNECT_TO" ] && extra_pool="${extra_pool},
            \"connect-to\": \"${NET_CONNECT_TO}\""
    [ -n "$tls_ca_path" ] && extra_pool="${extra_pool},
            \"tls-ca\": \"${tls_ca_path}\""
    # These two are process-wide in zmrig, so they go next to retries.
    local extra_root=""
    [ -n "$NET_IDLE_TIMEOUT" ] && extra_root="${extra_root},
    \"idle-timeout\": ${NET_IDLE_TIMEOUT}"
    [ -n "$NET_KEEPALIVE_INTERVAL" ] && extra_root="${extra_root},
    \"keepalive-interval\": ${NET_KEEPALIVE_INTERVAL}"

    # zmrig keeps a one-line report code in a file so the dashboard can price
    # the machine without running anything else. The C++ engine has no such
    # key, so it is only written for zmrig.
    if [ "${ENGINE:-xmrig}" = "zmrig" ] && [ "$NET_REPORT" = 1 ]; then
        local report_path="${NET_REPORT_FILE:-${STATE_DIR}/report.txt}"
        extra_root="${extra_root},
    \"report\": {
        \"enabled\": true,
        \"file\": \"${report_path}\",
        \"interval\": 60
    }"
    fi

    # Reject junk early: this value is pasted into JSON as a bare number.
    if [ -n "$NET_POWER" ]; then
        case "$NET_POWER" in
            ''|*[!0-9.]*) die "--power needs a number of watts, got '${NET_POWER}'" ;;
        esac
        extra_root="${extra_root},
    \"power\": ${NET_POWER}"
    fi

    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
{
    "api": {
        "id": null,
        "worker-id": "${rig}"
    },
    "http": {
        "enabled": ${http_enabled},
        "host": "127.0.0.1",
        "port": ${NET_HTTP_PORT},
        "access-token": ${http_token},
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
        "wrmsr": ${msr_flag},
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
        "affinity": ${affinity_json},
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
            "url": "${pool_url}",
            "user": "${WALLET}",
            "pass": "${POOL_PASS}",
            "rig-id": "${rig}",
            "nicehash": ${nicehash_flag},
            "keepalive": true,
            "enabled": true,
            "tls": ${tls_flag},
            "tls-fingerprint": null,
            "daemon": false,
            "socks5": null,
            "self-select": null,
            "submit-to-origin": false${extra_pool}
        }
    ],
    "print-time": 60,
    "health-print-time": 60,
    "dmi": true,
    "retries": 5,
    "retry-pause": 5${extra_root},
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
    info "pool:   ${pool_url}$([ "$tls_flag" = true ] && echo ' (TLS)')"
    if [ "$NET_CLOUDFLARE" = 1 ]; then
        info "mode:   Cloudflare-friendly WebSocket over TLS (${pool_url#wss://})"
        [ -n "$NET_PROXY" ] && info "proxy:  ${NET_PROXY}"
        [ -n "$NET_CONNECT_TO" ] && info "route:  connect ${NET_CONNECT_TO}, keep ${pool_url#wss://}"
    fi
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
    resolve_engine
    step "installing"
    as_root mkdir -p "$BIN_DIR" "$STATE_DIR"

    if [ "$ENGINE" = "zmrig" ]; then
        as_root install -m 0755 "${BUILD_DIR}/zmrig" "${ENGINE_BINARY}"
        # xmrig-ocean stays the name used by the service, logs and tooling.
        as_root ln -sf "${ENGINE_BINARY}" "${BINARY}"
    else
        as_root install -m 0755 "${BUILD_DIR}/xmrig" "${ENGINE_BINARY}"
        as_root ln -sf "${ENGINE_BINARY}" "${BINARY}"
    fi

    ok "binary: ${ENGINE_BINARY} ($("${ENGINE_BINARY}" --version 2>/dev/null | head -1))"
    printf '%s\n' "$ENGINE" | as_root tee "${CONFIG_DIR}/engine" >/dev/null 2>&1 || true

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

# restart is implemented as stop -> timestamp -> start so that a log line from
# the outgoing process can never be newer than LOG_SINCE (wait_ready and status
# parse the journal tail and would otherwise report the previous run).
svc_ctl() {
    if has_systemd && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        case "$1" in
            start)
                mark_log_start
                as_root systemctl start "${SERVICE_NAME}.service"
                ;;
            restart)
                as_root systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
                mark_log_start
                as_root systemctl start "${SERVICE_NAME}.service"
                ;;
            stop)
                as_root systemctl stop "${SERVICE_NAME}.service"
                ;;
            *)
                as_root systemctl "$1" "${SERVICE_NAME}.service"
                ;;
        esac
    else
        bg_ctl "$1"
    fi
}

# Timestamp of the last service start. wait_ready/status parse the journal tail,
# and without this they would happily read the previous run's hashrate line.
LOG_SINCE=""

mark_log_start() {
    LOG_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
}

PIDFILE="${STATE_DIR}/miner.pid"
LOGFILE="${STATE_DIR}/miner.log"

bg_start() {
    mark_log_start
    as_root mkdir -p "$STATE_DIR"
    if bg_running; then
        info "already running (pid $(cat "$PIDFILE" 2>/dev/null))"
        return 0
    fi
    # A fresh log per start: wait_ready and status parse the tail, so stale
    # lines from a previous run would be reported as current state.
    as_root sh -c ': > "$1"' _ "$LOGFILE"
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

    # Both engines print "speed 10s/60s/15m <a> <b> <c> H/s max <d> H/s"; keep
    # only the three numbers.
    local raw stamp line
    raw=$(log_tail 200 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'speed 10s/60s/15m' | tail -1) || true
    [ -n "$raw" ] || return 1

    # A line from the current run can still be minutes old when the miner is
    # stuck reconnecting; showing it would claim a hashrate that is not
    # happening. Anything older than 90 s is treated as stale.
    # journalctl prefixes its own timestamp, so take the last HH:MM:SS in the
    # line: that is the miner's.
    stamp=$(printf '%s' "$raw" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -1) || true
    if [ -n "$stamp" ]; then
        local then now delta
        then=$(date -d "today ${stamp}" +%s 2>/dev/null || echo 0)
        now=$(date +%s)
        if [ "$then" -gt 0 ]; then
            delta=$((now - then))
            [ "$delta" -lt 0 ] && delta=$((delta + 86400))
            [ "$delta" -le 90 ] || return 1
        fi
    fi

    line=$(printf '%s' "$raw" | grep -oE 'speed 10s/60s/15m [^H]*' \
           | sed 's/speed 10s\/60s\/15m //; s/[[:space:]]*$//') || true
    [ -n "$line" ] || return 1
    printf '%s\n' "$line"
}

# When this shell did not start the service, "since" has to come from systemd:
# otherwise journalctl happily returns the previous run's hashrate and status
# looks alive while the miner is stuck in a reconnect loop.
service_log_since() {
    if [ -n "${LOG_SINCE:-}" ]; then
        printf '%s' "$LOG_SINCE"
        return 0
    fi

    local stamp
    stamp=$(as_root systemctl show -p ActiveEnterTimestamp --value "${SERVICE_NAME}.service" 2>/dev/null || true)
    if [ -n "$stamp" ] && [ "$stamp" != "n/a" ]; then
        printf '%s' "$stamp"
        return 0
    fi

    return 1
}

log_tail() {
    local lines="${1:-40}"
    if has_systemd && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        local since
        since=$(service_log_since 2>/dev/null || true)
        if [ -n "$since" ]; then
            as_root journalctl -u "${SERVICE_NAME}.service" --since "$since" -n "$lines" --no-pager 2>/dev/null || true
        else
            as_root journalctl -u "${SERVICE_NAME}.service" -n "$lines" --no-pager 2>/dev/null || true
        fi
    elif [ -f "$LOGFILE" ]; then
        tail -n "$lines" "$LOGFILE" || true
    fi
}

# Same, but bounded in time. The journal keeps earlier runs of the unit name,
# so "does this run calibrate?" must not look at lines from an hour ago.
log_recent() {
    local minutes="${1:-5}"
    if has_systemd && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        local since
        since=$(service_log_since 2>/dev/null || true)
        if [ -n "$since" ]; then
            as_root journalctl -u "${SERVICE_NAME}.service" --since "$since" --no-pager 2>/dev/null || true
            return 0
        fi
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
        if [ -n "${LOG_SINCE:-}" ]; then
            as_root journalctl -u "${SERVICE_NAME}.service" --since "$LOG_SINCE" -n "$lines" --no-pager 2>/dev/null || true
            return 0
        fi
        as_root journalctl -u "${SERVICE_NAME}.service" -n "$lines" --no-pager 2>/dev/null || true
    elif [ -f "$LOGFILE" ]; then
        tail -n "$lines" "$LOGFILE" || true
    fi
}

# Seconds since systemd started the unit. Empty when unknown (no systemd, or a
# `date` that cannot parse systemd's timestamp format).
service_age() {
    has_systemd || return 1

    local ts
    ts=$(as_root systemctl show -p ActiveEnterTimestamp --value "${SERVICE_NAME}.service" 2>/dev/null) || return 1
    [ -n "$ts" ] || return 1

    local started now
    started=$(date -d "$ts" +%s 2>/dev/null) || return 1
    now=$(date +%s)

    [ "$started" -gt 0 ] 2>/dev/null || return 1
    printf '%s' "$((now - started))"
}

# ---------------------------------------------------------------------------
# self check
# ---------------------------------------------------------------------------
# The full self-test builds a 2 GiB dataset, which cannot fit next to a running
# full-memory miner. Fall back to the light variant (reference vectors only) in
# that case.
zmrig_self_test() {
    local binary="$1" level=""
    if [ "$(service_state)" = "active" ] || bg_running; then
        level="=light"
    fi

    "$binary" "--self-test${level}"
}

self_check() {
    resolve_root
    step "self-check"

    [ -x "$BINARY" ] && ok "binary installed: $("$BINARY" --version 2>/dev/null | head -1)" || fail "binary missing"

    if [ "${ENGINE:-xmrig}" = "zmrig" ]; then
        if zmrig_self_test "$BINARY" >/tmp/zmrig-selftest.$$ 2>&1; then
            if grep -q 'SKIP full-memory' /tmp/zmrig-selftest.$$; then
                ok "hash engine self-test: passed (reference vector, dataset check skipped while mining)"
            else
                ok "hash engine self-test: passed (RandomX reference vector + dataset)"
            fi
        else
            warn "hash engine self-test failed:"
            tail -5 /tmp/zmrig-selftest.$$ || true
        fi
        rm -f /tmp/zmrig-selftest.$$

        # zmrig has no donation code at all; prove it on the shipped binary.
        if have strings; then
            local dev_fee
            dev_fee=$(strings "$BINARY" | grep -ci "donat" || true)
            [ "${dev_fee:-0}" = 0 ] && ok "fee audit: no donation code in the binary (0%)" \
                                    || warn "found ${dev_fee} donation related strings, inspect manually"
        fi
    elif [ -x "${CONFIGURED_ROOT}/scripts/verify-fee-free.sh" ]; then
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
    resolve_engine

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
        # A reinstall must pick up the new binary and config, so restart when
        # the miner is already up instead of silently keeping the old process.
        if [ "$(service_state)" = "active" ] || bg_running; then
            svc_ctl restart >/dev/null 2>&1 || true
        else
            svc_ctl start >/dev/null 2>&1 || true
        fi
        wait_ready 90 || true
    fi

    self_check
    summary_card
}

cmd_update() {
    detect_os
    resolve_root
    step "updating sources"
    fetch_branch "$CONFIGURED_ROOT"
    checkout_branch "$CONFIGURED_ROOT"
    as_root git -C "$CONFIGURED_ROOT" pull --ff-only --quiet \
        || warn "could not fast-forward: local changes in ${CONFIGURED_ROOT}? run git -C ${CONFIGURED_ROOT} status"
    ok "sources at $(git -C "$CONFIGURED_ROOT" rev-parse --short HEAD) (branch ${REPO_BRANCH})"

    FORCE_REBUILD=1 build_miner
    install_binary
    svc_ctl restart >/dev/null 2>&1 || true
    wait_ready 60 || true
    self_check
}

cmd_uninstall() {
    step "uninstalling"
    resolve_engine
    svc_ctl stop >/dev/null 2>&1 || true
    if has_systemd; then
        as_root systemctl disable "${SERVICE_NAME}.service" "${SERVICE_NAME}-tune.service" >/dev/null 2>&1 || true
        as_root rm -f "$SERVICE_FILE" "$TUNE_SERVICE_FILE"
        as_root systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    # Both engines may be installed side by side, so remove both names and the
    # marker that tells later subcommands which one was in use.
    as_root rm -f "$BINARY" "${BIN_DIR}/xmrig-ocean" "${BIN_DIR}/zmrig" \
        "${BIN_DIR}/xmrig-ocean-tune" "${BIN_DIR}/xmrig-ocean-bench" "${BIN_DIR}/xmrig-ocean-verify"
    as_root rm -f "${CONFIG_DIR}/engine"
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
    start)     resolve_engine; svc_ctl start; ok "start requested" ;;
    stop)      resolve_engine; svc_ctl stop; ok "stop requested" ;;
    restart)   resolve_engine; svc_ctl restart; ok "restart requested" ;;
    status)
        resolve_engine
        step "status"
        state=$(service_state)
        info "service:  ${state}"
        if [ "$state" != "active" ]; then
            # The last hashrate line in the log is from the previous run; report
            # nothing rather than a number that looks live but is not.
            info "hashrate: n/a (the miner is not running, use 'start')"
        elif age=$(service_age) && [ "${age:-999}" -lt 40 ] 2>/dev/null; then
            # The previous process may have logged a hashrate line seconds
            # before this one started; do not report it as current.
            info "hashrate: warming up (started ${age}s ago, the dataset needs ~15s)"
        else
            hr=$(current_hashrate 2>/dev/null || true)
            shares=$(summary_shares 2>/dev/null || true)
            if printf '%s' "$hr" | grep -qE '[1-9][0-9]*(\.| )'; then
                info "hashrate: ${hr} H/s (10s/60s/15m)"
            elif [ -n "$shares" ] && [ "${shares%%/*}" != "0" ]; then
                info "hashrate: warming up (measurement window restarted)"
            else
                info "hashrate: no data yet (calibrating, connecting, or idle)"
            fi
        fi
        if [ -f "$CONFIG_FILE" ]; then
            info "config:   ${CONFIG_FILE}"
        fi
        info "huge pages: $(awk '$1 == "HugePages_Total:" { print $2 }' /proc/meminfo 2>/dev/null || echo '?') x 2 MiB"
        shares=$(summary_shares 2>/dev/null || true)
        [ -n "$shares" ] && info "shares:   ${shares} accepted"
        show_logs 6
        ;;
    logs)      resolve_engine; show_logs "${1:-40}" ;;
    bench)
        resolve_root
        resolve_engine
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
        if [ "${ENGINE:-xmrig}" = "zmrig" ]; then
            # Top-level dispatch, so no `local` here: plain prefixed variables.
            zm_hashes="${BENCH_HASHES:-20000}"
            "$binary" --bench="$zm_hashes" -c "$CONFIG_FILE" --no-color || rc=$?
        else
            "${CONFIGURED_ROOT}/scripts/bench.sh" --binary "$binary" "${ARGS[@]+"${ARGS[@]}"}" || rc=$?
        fi

        if [ "$was_running" = 1 ]; then
            svc_ctl start >/dev/null 2>&1 || true
            info "miner restarted"
        fi
        exit "$rc"
        ;;
    verify)
        resolve_root
        resolve_engine
        binary=$(find_binary) || die "no binary found, run the installer first"
        if [ "$ENGINE" = "zmrig" ]; then
            step "verifying zmrig"
            zmrig_self_test "$binary" || die "self-test failed"
            if have strings; then
                # Look for the donation *endpoints and wallets*, not for the
                # word "donate": the monitoring API legitimately reports
                # "donate_level": 0 in its JSON, which is not donation code.
                zm_dev_fee=$(strings "$binary" \
                    | grep -Eci "donate\.v2\.xmrig\.com|xmrig\.com/donate|44tLjm|donate\.moneroocean" \
                    || true)
                [ "${zm_dev_fee:-0}" = 0 ] && ok "no donation endpoints or wallets: 0% developer fee" \
                                           || die "${zm_dev_fee} donation endpoint/wallet string(s) found in the binary"
            fi
            ok "verified"
        else
            "${CONFIGURED_ROOT}/scripts/verify-fee-free.sh" --binary "$binary"
        fi
        ;;
    update)    cmd_update ;;
    report)
        resolve_root
        resolve_engine

        if [ "${ENGINE:-xmrig}" != "zmrig" ]; then
            die "the machine report needs the zmrig engine (this install uses '${ENGINE}')"
        fi

        binary=$(find_binary) || die "no binary found, run the installer first"
        [ -f "$CONFIG_FILE" ] || die "no config at ${CONFIG_FILE}, run the installer first"

        # The report needs the 2 GiB dataset, which the running service already
        # holds in huge pages: pause it, measure, bring it back.
        was_running=0
        if [ "$(service_state)" = "active" ]; then
            was_running=1
            info "pausing the miner so the report can build its own dataset"
            svc_ctl stop >/dev/null 2>&1 || true
            sleep 2
        fi

        report_args=()
        [ -n "$NET_POWER" ] && report_args+=("--power" "$NET_POWER")

        rc=0
        "$binary" -c "$CONFIG_FILE" --report --no-color "${report_args[@]}" || rc=$?

        if [ "$was_running" = 1 ]; then
            svc_ctl start >/dev/null 2>&1 || true
            info "miner restarted"
        fi
        exit "$rc"
        ;;
    uninstall) cmd_uninstall ;;
    *)         fail "unknown command: ${COMMAND}"; usage; exit 1 ;;
esac
