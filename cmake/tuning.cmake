# XMRig performance tuning
#
# This module is included right after cmake/flags.cmake and adds the compiler
# level knobs that actually move the hashrate needle on CPU mining:
#
#   * -march=native / -mtune=native  -> use every ISA extension of the build host
#                                       (AVX-512/VAES for RandomX & CryptoNight,
#                                       BMI2/ADX, better instruction selection).
#   * LTO                            -> inline the miner's hot abstraction layers
#                                       (hash dispatch, job accessors, logging
#                                       guards) into the worker thread loops and
#                                       drop the PLT indirection between them.
#   * PGO                            -> profile guided layout of the JIT helper
#                                       paths, Blake2b, AES hash and dataset init.
#   * -fno-plt                       -> one less indirect call per external call
#                                       in the RandomX dataset initialiser.
#
# Native tuning and the extra micro flags are ON by default for release builds
# because this fork targets one thing: the highest possible hashrate on the
# machine it was built on. LTO is opt-in: it breaks CryptoNight with GCC 12 in
# this tree (see the comment at section 3) and cannot help RandomX, which is
# JIT compiled at runtime.

include(CheckCXXCompilerFlag)

option(XMRIG_NATIVE_OPT "Tune for the build machine (-march=native -mtune=native)" ON)
option(WITH_LTO        "Enable link time optimization for release builds (NOT recommended, see below)" OFF)
option(WITH_EXTRA_OPT  "Enable additional low level release flags (-fno-plt, alignment)" ON)

set(XMRIG_PGO "" CACHE STRING "Profile guided optimization: OFF|generate|use")
set(XMRIG_PGO_DIR "${CMAKE_BINARY_DIR}/pgo" CACHE PATH "Directory with PGO profile data")

string(TOLOWER "${XMRIG_PGO}" XMRIG_PGO_MODE)

set(XMRIG_TUNING_FLAGS "")
set(XMRIG_TUNING_LINK_FLAGS "")

if (CMAKE_BUILD_TYPE STREQUAL "Release" AND (CMAKE_CXX_COMPILER_ID MATCHES GNU OR CMAKE_CXX_COMPILER_ID MATCHES Clang))
    # ---------------------------------------------------------------------
    # 1. Native ISA tuning. Skipped for cross builds and for targets where a
    #    fixed -march is already forced (ARM/RISC-V), otherwise the two flag
    #    sets would conflict.
    # ---------------------------------------------------------------------
    if (XMRIG_NATIVE_OPT AND NOT CMAKE_CROSSCOMPILING AND NOT ARM_TARGET AND NOT XMRIG_RISCV)
        CHECK_CXX_COMPILER_FLAG("-march=native" XMRIG_HAS_MARCH_NATIVE)

        if (XMRIG_HAS_MARCH_NATIVE)
            set(XMRIG_TUNING_FLAGS "${XMRIG_TUNING_FLAGS} -march=native -mtune=native")
            message(STATUS "Tuning: -march=native -mtune=native (binary is host specific, use -DXMRIG_NATIVE_OPT=OFF for a portable build)")
        endif()
    endif()

    # ---------------------------------------------------------------------
    # 2. Extra micro flags. Cheap, safe and measurable on x86-64.
    # ---------------------------------------------------------------------
    if (WITH_EXTRA_OPT)
        CHECK_CXX_COMPILER_FLAG("-fno-plt" XMRIG_HAS_FNO_PLT)
        if (XMRIG_HAS_FNO_PLT)
            set(XMRIG_TUNING_FLAGS "${XMRIG_TUNING_FLAGS} -fno-plt")
        endif()

        CHECK_CXX_COMPILER_FLAG("-falign-functions=32" XMRIG_HAS_ALIGN)
        if (XMRIG_HAS_ALIGN)
            # Keep the RandomX JIT entry points, dataset initialiser and AES
            # hash loops on their own cache lines.
            set(XMRIG_TUNING_FLAGS "${XMRIG_TUNING_FLAGS} -falign-functions=32 -falign-loops=32")
        endif()
    endif()

    # ---------------------------------------------------------------------
    # 3. Link time optimization.
    #
    # Disabled by default: GCC 12 miscompiles the CryptoNight reference
    # implementations when they are inlined across translation units during
    # LTO. The symptom is "thread #N self-test failed" and the CPU backend
    # refusing to start for every cn/* algorithm (verified with
    # `node run_tests.js --suite miner-integration`). RandomX does not benefit
    # from LTO at all (it is JIT compiled at runtime), so there is no upside.
    # ---------------------------------------------------------------------
    if (WITH_LTO AND NOT XMRIG_PGO_MODE)
        message(WARNING "WITH_LTO=ON: CryptoNight self-test may fail with GCC. Run the hash and miner integration tests before deploying this binary.")
        if (CMAKE_CXX_COMPILER_ID MATCHES GNU)
            CHECK_CXX_COMPILER_FLAG("-flto=auto" XMRIG_HAS_LTO_AUTO)
            if (XMRIG_HAS_LTO_AUTO)
                set(XMRIG_TUNING_FLAGS "${XMRIG_TUNING_FLAGS} -flto=auto")
            else()
                set(XMRIG_TUNING_FLAGS "${XMRIG_TUNING_FLAGS} -flto")
            endif()
        else()
            set(XMRIG_TUNING_FLAGS "${XMRIG_TUNING_FLAGS} -flto")
        endif()

        set(XMRIG_TUNING_LINK_FLAGS "${XMRIG_TUNING_LINK_FLAGS} -flto")
        message(STATUS "Tuning: link time optimization enabled")
    endif()

    # ---------------------------------------------------------------------
    # 4. Profile guided optimization.
    #
    #   cmake -DXMRIG_PGO=generate ...   # instrumented build (headers only, no training)
    #   ./xmrig --bench=1M               # train (scripts/build-optimized.sh --pgo does this)
    #   cmake -DXMRIG_PGO=use ...        # optimised build consuming the profile
    # ---------------------------------------------------------------------
    if (XMRIG_PGO_MODE STREQUAL "generate")
        set(XMRIG_TUNING_FLAGS "${XMRIG_TUNING_FLAGS} -fprofile-generate=${XMRIG_PGO_DIR}")
        set(XMRIG_TUNING_LINK_FLAGS "${XMRIG_TUNING_LINK_FLAGS} -fprofile-generate=${XMRIG_PGO_DIR}")
        message(STATUS "Tuning: PGO instrumentation (-fprofile-generate=${XMRIG_PGO_DIR})")
    elseif (XMRIG_PGO_MODE STREQUAL "use")
        set(XMRIG_TUNING_FLAGS "${XMRIG_TUNING_FLAGS} -fprofile-use=${XMRIG_PGO_DIR} -fprofile-correction -Wno-missing-profile")
        set(XMRIG_TUNING_LINK_FLAGS "${XMRIG_TUNING_LINK_FLAGS} -fprofile-use=${XMRIG_PGO_DIR} -fprofile-correction")
        message(STATUS "Tuning: PGO optimisation (-fprofile-use=${XMRIG_PGO_DIR})")
    elseif (NOT XMRIG_PGO_MODE STREQUAL "")
        message(WARNING "Unknown XMRIG_PGO value '${XMRIG_PGO}', expected generate or use")
    endif()

    set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} ${XMRIG_TUNING_FLAGS}")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${XMRIG_TUNING_FLAGS}")

    if (XMRIG_TUNING_LINK_FLAGS)
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${XMRIG_TUNING_LINK_FLAGS}")
    endif()

    # The RandomX static assembly and the CryptoNight JIT both benefit from a
    # non-executable stack and a properly separated text section, but they must
    # not be reordered by the linker, hence no --sort-section here.
elseif (CMAKE_CXX_COMPILER_ID MATCHES MSVC AND CMAKE_BUILD_TYPE STREQUAL "Release")
    # /GL is already in cmake/flags.cmake, this only makes the linker use it and
    # adds the same intent as -march=native for the MSVC toolchain.
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} /LTCG /OPT:REF /OPT:ICF")

    if (WITH_EXTRA_OPT)
        add_definitions(-DHAVE_ROTR)
        set(CMAKE_C_FLAGS_RELEASE   "${CMAKE_C_FLAGS_RELEASE} /Ob3 /Oi /Oy- /Gy /Gw")
        set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} /Ob3 /Oi /Oy- /Gy /Gw")
    endif()

    message(STATUS "Tuning: MSVC /GL /LTCG /Ob3")
endif()

