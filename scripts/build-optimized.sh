#!/usr/bin/env bash
#
# build-optimized.sh - build this fork with the settings that matter for mining.
#
#   ./scripts/build-optimized.sh                  # native Release build, CPU only
#   ./scripts/build-optimized.sh --portable       # redistributable (no -march=native)
#   ./scripts/build-optimized.sh --pgo            # profile guided optimisation (slower)
#   ./scripts/build-optimized.sh --lto            # link time optimisation (see docs: breaks CN on GCC)
#   ./scripts/build-optimized.sh --with-tls --all-backends
#   ./scripts/build-optimized.sh --clean --jobs 8
#
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/.." && pwd)
BUILD_DIR="${BUILD_DIR:-${ROOT}/build}"
JOBS=$( (command -v nproc >/dev/null && nproc) || echo 4 )

NATIVE=ON
LTO=OFF
PGO=0
PGO_SECONDS=180
STATIC=0
TLS=auto
HWLOC=auto
BACKENDS=0
CLEAN=0
CMAKE_ARGS=()

color() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
info() { printf '%s %s\n' "$(color '1;36' '*')" "$*"; }
ok()   { printf '%s %s\n' "$(color '1;32' 'OK')" "$*"; }
warn() { printf '%s %s\n' "$(color '1;33' '!')" "$*"; }
die()  { printf '%s %s\n' "$(color '1;31' 'x')" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --portable)     NATIVE=OFF ;;
        --native)       NATIVE=ON ;;
        --lto)          LTO=ON ;;
        --no-lto)       LTO=OFF ;;
        --pgo)          PGO=1 ;;
        --pgo-seconds)  PGO_SECONDS="${2:?}"; shift ;;
        --pgo-seconds=*) PGO_SECONDS="${1#*=}" ;;
        --with-tls)     TLS=ON ;;
        --no-tls)       TLS=OFF ;;
        --with-hwloc)   HWLOC=ON ;;
        --no-hwloc)     HWLOC=OFF ;;
        --all-backends) BACKENDS=1 ;;
        --static)       STATIC=1 ;;
        --clean)        CLEAN=1 ;;
        --jobs)         JOBS="${2:?}"; shift ;;
        --jobs=*)       JOBS="${1#*=}" ;;
        --build-dir)    BUILD_DIR="${2:?}"; shift ;;
        --build-dir=*)  BUILD_DIR="${1#*=}" ;;
        -h|--help)      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              CMAKE_ARGS+=("$1") ;;
    esac
    shift
done

command -v cmake >/dev/null || die "cmake not found. Debian/Ubuntu: sudo apt install cmake build-essential"
command -v c++   >/dev/null || die "no C++ compiler found. Debian/Ubuntu: sudo apt install build-essential"

# ---------------------------------------------------------------------------
# Dependency detection (same requirements as upstream XMRig)
# ---------------------------------------------------------------------------
find_header() {
    local name="$1"
    for d in /usr/include /usr/local/include /opt/homebrew/include /usr/include/x86_64-linux-gnu; do
        [ -f "$d/$name" ] && return 0
    done
    return 1
}

if [ "$TLS" = auto ]; then
    if find_header openssl/ssl.h; then TLS=ON; else TLS=OFF; fi
fi
if [ "$HWLOC" = auto ]; then
    if find_header hwloc.h; then HWLOC=ON; else HWLOC=OFF; fi
fi

if ! find_header uv.h && [ -z "${UV_INCLUDE_DIR:-}" ]; then
    cat >&2 <<'EOF'
  libuv headers were not found (uv.h). Install them first:
      Debian/Ubuntu: sudo apt install libuv1-dev libhwloc-dev libssl-dev
      Fedora:        sudo dnf install libuv-devel hwloc-devel openssl-devel
      Arch:          sudo pacman -S libuv hwloc openssl
  or point the build at a local copy:
      cmake -DUV_INCLUDE_DIR=/path/to/libuv/include -DUV_LIBRARY=/path/to/libuv.a
EOF
    exit 1
fi

if [ "$HWLOC" = OFF ]; then
    warn "building without hwloc: NUMA aware dataset placement and CPU topology detection are lost"
fi
if [ "$TLS" = OFF ]; then
    info "building without TLS (plain stratum only)"
fi
if [ "$NATIVE" = ON ]; then
    info "native tuning enabled (binary will only run on this CPU model)"
else
    info "portable build (baseline x86-64 ISA)"
fi

# Allow a locally built libuv/hwloc to be used, e.g.
#   UV_INCLUDE_DIR=~/libuv/include UV_LIBRARY=~/libuv/build/libuv.a ./scripts/build-optimized.sh
if [ -n "${UV_INCLUDE_DIR:-}" ]; then
    CMAKE_ARGS+=(-DUV_INCLUDE_DIR="$UV_INCLUDE_DIR")
fi
if [ -n "${UV_LIBRARY:-}" ]; then
    CMAKE_ARGS+=(-DUV_LIBRARY="$UV_LIBRARY")
fi
if [ -n "${HWLOC_INCLUDE_DIR:-}" ]; then
    CMAKE_ARGS+=(-DHWLOC_INCLUDE_DIR="$HWLOC_INCLUDE_DIR")
fi

CMAKE_OPTS=(
    -DCMAKE_BUILD_TYPE=Release
    -DXMRIG_NATIVE_OPT="$NATIVE"
    -DWITH_LTO="$LTO"
    -DWITH_EXTRA_OPT=ON
    -DWITH_TLS="$TLS"
    -DWITH_HWLOC="$HWLOC"
    -DBUILD_STATIC="$STATIC"
)

if [ "$BACKENDS" -eq 0 ]; then
    info "CPU-only build (OpenCL/CUDA disabled, fewer dependencies, same CPU hashrate)"
    CMAKE_OPTS+=(-DWITH_OPENCL=OFF -DWITH_CUDA=OFF -DWITH_NVML=OFF -DWITH_ADL=OFF)
fi

configure_and_build() {
    local dir="$1"; shift
    cmake -S "$ROOT" -B "$dir" "${CMAKE_OPTS[@]}" "$@" | grep -E "Tuning|Detected|error|Error" || true
    cmake --build "$dir" --parallel "$JOBS"
}

if [ "$PGO" -eq 1 ]; then
    command -v g++ >/dev/null || die "--pgo currently supports GCC only"

    info "step 1/3: instrumented build -> ${BUILD_DIR}/pgo-gen"
    configure_and_build "${BUILD_DIR}/pgo-gen" -DXMRIG_PGO=generate

    local_xmrig=$(find "${BUILD_DIR}/pgo-gen" -maxdepth 1 -type f -name 'xmrig*' -perm -u+x | head -1)
    [ -n "$local_xmrig" ] || die "instrumented binary not found"

    info "step 2/3: training for ${PGO_SECONDS}s (RandomX benchmark, SIGTERM is handled cleanly)"
    set +e
    timeout --signal=TERM "${PGO_SECONDS}" "$local_xmrig" --bench=1M --print-time=30 >/dev/null 2>&1
    set -e

    info "step 3/3: optimised build -> ${BUILD_DIR}/pgo-use"
    configure_and_build "${BUILD_DIR}/pgo-use" \
        -DXMRIG_PGO=use -DXMRIG_PGO_DIR="${BUILD_DIR}/pgo-gen/pgo"

    final=$(find "${BUILD_DIR}/pgo-use" -maxdepth 1 -type f -name 'xmrig*' -perm -u+x | head -1)
    [ -n "$final" ] || die "PGO binary not found"
    cp -f "$final" "${BUILD_DIR}/xmrig"
    ok "PGO build: ${BUILD_DIR}/xmrig"
else
    if [ "$CLEAN" -eq 1 ]; then
        rm -rf "$BUILD_DIR"
    fi
    if [ "${#CMAKE_ARGS[@]}" -gt 0 ]; then
        configure_and_build "$BUILD_DIR" "${CMAKE_ARGS[@]}"
    else
        configure_and_build "$BUILD_DIR"
    fi

    built=$(find "$BUILD_DIR" -maxdepth 1 -type f -perm -u+x -name 'xmrig*' | head -1)
    [ -n "$built" ] || die "build finished but no xmrig binary was produced in ${BUILD_DIR}"
    if [ "$built" != "${BUILD_DIR}/xmrig" ]; then
        cp -f "$built" "${BUILD_DIR}/xmrig"
    fi
    ok "build: ${BUILD_DIR}/xmrig (from $(basename "$built"))"
fi

if [ ! -x "${BUILD_DIR}/xmrig" ]; then
    die "${BUILD_DIR}/xmrig is missing"
fi

echo
"${BUILD_DIR}/xmrig" --version
cat <<EOF

Next steps:
  sudo ./scripts/tune-linux.sh          # huge pages, THP, governor, MSR
  ./scripts/bench.sh                    # measure RandomX H/s
  ./scripts/verify-fee-free.sh          # prove that the binary has no dev fee
EOF
