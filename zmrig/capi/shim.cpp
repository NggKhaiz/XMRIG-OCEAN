/* ZMRIG (by @nggkhaiz) - compatibility shim for the standalone hash library.
 *
 * Two symbols that RandomX needs normally live in XMRig's miner layer, which
 * we deliberately do not link:
 *
 *   rx_blake2b / rx_blake2b_compress  dispatch pointers defined in
 *                                    src/crypto/rx/Rx.cpp
 *   cn_sse41_enabled / cn_vaes_enabled
 *                                    CryptoNight feature flags probed by
 *                                    BasicCpuInfo (unused by RandomX)
 *
 * The dispatch pointers are set to the fastest implementations this build was
 * compiled with, exactly like XMRig does on an AVX2 + SSE4.1 CPU.
 */

#include <cstddef>
#include <cstdint>

#include <time.h>

#include "base/io/log/Log.h"
#include "crypto/randomx/blake2/avx2/blake2b.h"
#include "crypto/randomx/blake2/blake2.h"

void (*rx_blake2b_compress)(blake2b_state *S, const uint8_t *block) = rx_blake2b_compress_sse41;
int  (*rx_blake2b)(void *out, size_t outlen, const void *in, size_t inlen) = blake2b_avx2;

bool cn_sse41_enabled = true;
bool cn_vaes_enabled  = false;

/* Logging is owned by the Zig frontend, so the C++ side only needs the qword
 * that Assembly/Cpu.cpp test via the inline isVerbose() helpers. */
namespace xmrig {

bool        Log::m_background = false;
bool        Log::m_colors     = false;
LogPrivate *Log::d            = nullptr;
uint32_t    Log::m_verbose    = 0;

void Log::print(const char *, ...) {}
void Log::print(Level, const char *, ...) {}

} // namespace xmrig

/* argon2's implementation selector times its candidates with libuv's clock;
 * the miner does not use libuv, so provide the one symbol it asks for. */
extern "C" unsigned long long uv_hrtime(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);

    return static_cast<unsigned long long>(ts.tv_sec) * 1000000000ULL
         + static_cast<unsigned long long>(ts.tv_nsec);
}
