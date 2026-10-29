#!/usr/bin/env bash
#
# build.sh - build the zmrig binary: the hash engine (C++ from this repo) plus
# the miner (Zig).
#
#   ./zmrig/build.sh                 # release build into zmrig/out/zmrig
#   ./zmrig/build.sh --jobs 8        # parallel C++ compile
#   ./zmrig/build.sh --no-zig        # only rebuild libxmorx.a
#   ./zmrig/build.sh --portable      # no -march=native (run on any x86-64)
#   ./zmrig/build.sh --output DIR    # write the binary/objects to DIR
#
# Requirements: g++, ar, zig 0.13 (or set ZIG=/path/to/zig).
# The Zig part has no external dependencies - nothing is downloaded.
#
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${0}")/.." && pwd)
HERE="${ROOT}/zmrig"
OUT="${OUT_DIR:-${HERE}/out}"
OBJ="${OUT}/obj"
JOBS=$(nproc 2>/dev/null || echo 2)
BUILD_ZIG=1
MARCH="-march=native"
ZIG="${ZIG:-zig}"

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs)      JOBS="${2:?}"; shift ;;
        --jobs=*)    JOBS="${1#*=}" ;;
        --output)    OUT="${2:?}"; OBJ="${OUT}/obj"; shift ;;
        --output=*)  OUT="${1#*=}"; OBJ="${OUT}/obj" ;;
        --no-zig)    BUILD_ZIG=0 ;;
        --portable)  MARCH="" ;;
        -h|--help)   sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

command -v g++ >/dev/null || { echo "g++ is required" >&2; exit 1; }

FLAGS_SIG=$(printf '%s\n' "${CXXFLAGS[@]}" "${CFLAGS[@]}" "${ARGON_CFLAGS[@]}" | sha256sum | cut -d' ' -f1)

if [ -d "$OBJ" ] && [ "$(cat "$OBJ/.flags" 2>/dev/null)" != "$FLAGS_SIG" ]; then
    echo "==> compiler flags changed, rebuilding everything"
    rm -rf "$OBJ"
fi

mkdir -p "$OBJ"
printf '%s\n' "$FLAGS_SIG" > "$OBJ/.flags"

CXXFLAGS=(
    -std=c++11 -O3 -DNDEBUG -DXMRIG_FEATURE_ASM -DXMRIG_VAES -fno-rtti -fexceptions -pthread
    -maes -Wall -Wno-strict-aliasing -Wno-class-memaccess
    -I"${ROOT}/src" -I"${ROOT}/src/3rdparty" -I"${ROOT}/src/crypto/randomx"
    -I"${HERE}/capi"
)
[ -n "$MARCH" ] && CXXFLAGS+=("$MARCH" -mtune=native -fno-plt)
# shellcheck disable=SC2206
[ -n "${EXTRA_FLAGS:-}" ] && { CXXFLAGS+=(${EXTRA_FLAGS}); }

CFLAGS=(
    -O3 -DNDEBUG -DXMRIG_FEATURE_ASM -pthread -maes -std=gnu99 -fno-strict-aliasing
    -I"${ROOT}/src" -I"${ROOT}/src/3rdparty" -I"${ROOT}/src/crypto/randomx"
)
# argon2 ships its own blake2.h; src/crypto/randomx would shadow it and the two
# structs have different layouts, so these files get their own include order.
ARGON_CFLAGS=(
    -O3 -DNDEBUG -DXMRIG_FEATURE_ASM -pthread -maes -std=gnu99 -fno-strict-aliasing
    -I"${ROOT}/src/3rdparty/argon2/lib" -I"${ROOT}/src/3rdparty/argon2/include"
    -I"${ROOT}/src/3rdparty/argon2" -I"${ROOT}/src/3rdparty" -I"${ROOT}/src"
)
[ -n "$MARCH" ] && CFLAGS+=("$MARCH" -mtune=native -fno-plt)
[ -n "$MARCH" ] && ARGON_CFLAGS+=("$MARCH" -mtune=native -fno-plt)
# shellcheck disable=SC2206
[ -n "${EXTRA_FLAGS:-}" ] && { CFLAGS+=(${EXTRA_FLAGS}); ARGON_CFLAGS+=(${EXTRA_FLAGS}); }

RX="${ROOT}/src/crypto/randomx"

# --- C++: RandomX core, the XMRig allocator it depends on, RxAlgo, the shim ---
CXX_SOURCES=(
    "${RX}/aes_hash.cpp"
    "${RX}/aes_hash_vaes512.cpp"
    "${RX}/allocator.cpp"
    "${RX}/blake2_generator.cpp"
    "${RX}/bytecode_machine.cpp"
    "${RX}/dataset.cpp"
    "${RX}/instructions_portable.cpp"
    "${RX}/randomx.cpp"
    "${RX}/soft_aes.cpp"
    "${RX}/superscalar.cpp"
    "${RX}/virtual_machine.cpp"
    "${RX}/virtual_memory.cpp"
    "${RX}/vm_compiled.cpp"
    "${RX}/vm_compiled_light.cpp"
    "${RX}/vm_interpreted.cpp"
    "${RX}/vm_interpreted_light.cpp"
    "${RX}/jit_compiler_x86.cpp"
    "${ROOT}/src/crypto/common/VirtualMemory.cpp"
    "${ROOT}/src/crypto/common/VirtualMemory_unix.cpp"
    "${ROOT}/src/crypto/common/HugePagesInfo.cpp"
    "${ROOT}/src/crypto/common/MemoryPool.cpp"
    "${ROOT}/src/crypto/common/LinuxMemory.cpp"
    "${ROOT}/src/crypto/common/Assembly.cpp"
    "${ROOT}/src/crypto/rx/RxAlgo.cpp"
    "${ROOT}/src/crypto/rx/RxFix_linux.cpp"
    "${ROOT}/src/backend/cpu/Cpu.cpp"
    "${ROOT}/src/backend/cpu/CpuThread.cpp"
    "${ROOT}/src/backend/cpu/CpuThreads.cpp"
    "${ROOT}/src/backend/cpu/platform/BasicCpuInfo.cpp"
    "${ROOT}/src/base/crypto/Algorithm.cpp"
    "${ROOT}/src/base/tools/Chrono.cpp"
    "${ROOT}/src/base/tools/String.cpp"
    "${ROOT}/src/base/io/json/Json.cpp"
    "${ROOT}/src/3rdparty/fmt/format.cc"
    "${HERE}/capi/xmo_randomx.cpp"
    "${HERE}/capi/xmo_msr.cpp"
    "${HERE}/capi/shim.cpp"
)

# --- C: blake2, argon2 (cache initialisation), panthera helpers ---
C_SOURCES=(
    "${RX}/blake2/blake2b.c"
    "${RX}/blake2/blake2b_sse41.c"
    "${RX}/blake2/avx2/blake2b_avx2.c"
    "${RX}/reciprocal.c"
    "${RX}/panthera/sha256.c"
    "${RX}/panthera/KangarooTwelve.c"
    "${RX}/panthera/KeccakP-1600-reference.c"
    "${RX}/panthera/KeccakSpongeWidth1600.c"
    "${RX}/panthera/yespower-opt.c"
)

ARGON_SOURCES=(
    "${ROOT}/src/3rdparty/argon2/lib/argon2.c"
    "${ROOT}/src/3rdparty/argon2/lib/core.c"
    "${ROOT}/src/3rdparty/argon2/lib/blake2/blake2.c"
    "${ROOT}/src/3rdparty/argon2/lib/encoding.c"
    "${ROOT}/src/3rdparty/argon2/lib/genkat.c"
    "${ROOT}/src/3rdparty/argon2/lib/impl-select.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-arch.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-avx2.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-avx512f.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-sse2.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-ssse3.c"
    "${ROOT}/src/3rdparty/argon2/arch/x86_64/lib/argon2-xop.c"
)

ASM_SOURCES=(
    "${RX}/jit_compiler_x86_static.S"
)

obj_path() {
    # Flatten the path so two files with the same basename cannot collide.
    local src="$1"
    local rel="${src#${ROOT}/}"
    printf '%s/%s.o' "$OBJ" "${rel//\//_}"
}

echo "==> compiling hash engine ($(( ${#CXX_SOURCES[@]} + ${#C_SOURCES[@]} + ${#ARGON_SOURCES[@]} + ${#ASM_SOURCES[@]} )) files, -j${JOBS})"

objects=()
compile_one() {
    local src="$1" obj="$2"
    local ext="${src##*.}"
    case "$ext" in
        c)
            case "$src" in
                */3rdparty/argon2/*) cc "${ARGON_CFLAGS[@]}" -x c -c "$src" -o "$obj" ;;
                *)                   cc "${CFLAGS[@]}" -x c -c "$src" -o "$obj" ;;
            esac ;;
        S)
            cc "${CFLAGS[@]}" -x assembler-with-cpp -c "$src" -o "$obj" ;;
        *)
            # The VAES-512 AES routine needs its own ISA even when the build host
            # has none (-march=native only covers the machine doing the build).
            # Without this the file fails to compile on a CPU without AVX-512,
            # which made `./build.sh --portable` and older build hosts unusable.
            # The routine is only ever called behind a runtime CPUID check.
            case "$src" in
                */aes_hash_vaes512.cpp)
                    c++ "${CXXFLAGS[@]}" -mvaes -mavx512f -mavx512vl -c "$src" -o "$obj" ;;
                *)
                    c++ "${CXXFLAGS[@]}" -c "$src" -o "$obj" ;;
            esac ;;
    esac
}

# A background compile must not be able to fail silently: the archive would
# then be built from stale objects.
compile_bg() {
    compile_one "$1" "$2" || : > "${OBJ}/.failed"
}

rm -f "${OBJ}/.failed"

for src in "${CXX_SOURCES[@]}" "${C_SOURCES[@]}" "${ARGON_SOURCES[@]}" "${ASM_SOURCES[@]}"; do
    obj=$(obj_path "$src")
    objects+=("$obj")
    if [ -f "$obj" ] && [ "$obj" -nt "$src" ]; then
        continue
    fi
    compile_bg "$src" "$obj" &
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
done
wait || true

if [ -f "${OBJ}/.failed" ]; then
    rm -f "${OBJ}/.failed"
    echo "error: compilation failed" >&2
    exit 1
fi

echo "==> archiving libxmorx.a"
rm -f "${OUT}/libxmorx.a"
ar rcs "${OUT}/libxmorx.a" "${objects[@]}"

if [ "${OUT_DIR:-}" != "" ] && [ "$BUILD_ZIG" -eq 1 ]; then BUILD_ZIG=0; fi

if [ "$BUILD_ZIG" -eq 0 ]; then
    echo "built ${OUT}/libxmorx.a"
    exit 0
fi

# Zig can come from PATH, from ZIG=..., or from the `ziglang` pip package
# (the usual way to get it on a machine without a package manager).
if ! command -v "$ZIG" >/dev/null; then
    if python3 -c "import ziglang" >/dev/null 2>&1; then
        ZIG=$(python3 -c "import ziglang, os; print(os.path.join(os.path.dirname(ziglang.__file__), 'zig'))")

        [ -x "$ZIG" ] || chmod +x "$ZIG" 2>/dev/null || true
    fi
fi

command -v "$ZIG" >/dev/null || [ -x "$ZIG" ] || { echo "zig not found (set ZIG=/path/to/zig, or pip install ziglang==0.13.0)" >&2; exit 1; }

echo "==> building zmrig ($($ZIG version))"

CPU_FLAG=()
[ -n "$MARCH" ] && CPU_FLAG=(-mcpu=native)

# The hash engine is C++, so the binary needs the C++ runtime and the unwinder.
# Zig does not resolve plain "-lstdc++", so pass the real files.
LIBSTDCXX=$(c++ -print-file-name=libstdc++.so 2>/dev/null)
LIBGCC_S=$(c++ -print-file-name=libgcc_s.so.1 2>/dev/null)
[ -f "${LIBSTDCXX:-/nonexistent}" ] || LIBSTDCXX=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
[ -f "${LIBGCC_S:-/nonexistent}" ] || LIBGCC_S=/usr/lib/x86_64-linux-gnu/libgcc_s.so.1

"$ZIG" build-exe "${HERE}/src/main.zig" \
    -O ReleaseFast "${CPU_FLAG[@]}" \
    --name zmrig \
    -femit-bin="${OUT}/zmrig" \
    --cache-dir "${OUT}/zig-cache" \
    --global-cache-dir "${OUT}/zig-global" \
    -lc -lpthread -lm \
    -L"${OUT}" -lxmorx "${LIBSTDCXX}" "${LIBGCC_S}"

echo
echo "built ${OUT}/zmrig"
"${OUT}/zmrig" --version 2>/dev/null || true
