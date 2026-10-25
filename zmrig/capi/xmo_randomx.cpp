/* XMRig Ocean - hash engine C API implementation.
 *
 * Thin, allocation-aware wrapper around the RandomX build in this repository.
 * Everything performance relevant happens inside RandomX itself; this file only
 * decides where the cache/dataset/scratchpad memory lives (huge pages when the
 * kernel has them) and how many threads initialise the dataset.
 */

#include "xmo_randomx.h"

#include "base/crypto/Algorithm.h"
#include "crypto/randomx/configuration.h"
#include "crypto/randomx/randomx.h"
#include "crypto/rx/RxAlgo.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#ifdef __linux__
#include <sys/mman.h>
#include <unistd.h>
#endif

namespace {

constexpr size_t kHugePageSize = 2 * 1024 * 1024;
constexpr size_t kScratchpad   = RANDOMX_SCRATCHPAD_L3_MAX_SIZE;

/* 2 MiB aligned, backed by explicit huge pages when the kernel reserved some.
 * Falls back to anonymous memory with THP hints, which is what a normal build
 * of XMRig ends up with on a host without reserved pages. */
uint8_t *mapPages(size_t bytes, bool huge, size_t *mapped)
{
    const size_t aligned = (bytes + kHugePageSize - 1) & ~(kHugePageSize - 1);

#ifdef __linux__
    if (huge) {
        void *p = mmap(nullptr, aligned, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
        if (p != MAP_FAILED) {
            *mapped = aligned;

            return static_cast<uint8_t *>(p);
        }
    }
#endif

    void *p = nullptr;
#ifdef __linux__
    if (posix_memalign(&p, kHugePageSize, aligned) != 0) {
        return nullptr;
    }

    std::memset(p, 0, aligned);

    if (huge) {
        madvise(p, aligned, MADV_HUGEPAGE);
    }
#else
    (void) huge;
    if (posix_memalign(&p, kHugePageSize, aligned) != 0) {
        return nullptr;
    }
    std::memset(p, 0, aligned);
#endif

    *mapped = aligned;

    return static_cast<uint8_t *>(p);
}


void unmapPages(uint8_t *p, size_t bytes)
{
    if (!p) {
        return;
    }

    const size_t aligned = (bytes + kHugePageSize - 1) & ~(kHugePageSize - 1);

#ifdef __linux__
    munmap(p, aligned);
#else
    free(p);
#endif
}


void setError(char *err, size_t errlen, const char *message)
{
    if (!err || errlen == 0) {
        return;
    }

    std::snprintf(err, errlen, "%s", message);
}


xmrig::Algorithm toAlgorithm(int algo)
{
    switch (algo) {
    case XMO_RX_2:     return xmrig::Algorithm(xmrig::Algorithm::RX_V2);
    case XMO_RX_WOW:   return xmrig::Algorithm(xmrig::Algorithm::RX_WOW);
    case XMO_RX_ARQ:   return xmrig::Algorithm(xmrig::Algorithm::RX_ARQ);
    case XMO_RX_GRAFT: return xmrig::Algorithm(xmrig::Algorithm::RX_GRAFT);
    case XMO_RX_SFX:   return xmrig::Algorithm(xmrig::Algorithm::RX_SFX);
    case XMO_RX_YADA:  return xmrig::Algorithm(xmrig::Algorithm::RX_YADA);
    case XMO_RX_XLA:   return xmrig::Algorithm(xmrig::Algorithm::RX_XLA);
    default:           return xmrig::Algorithm(xmrig::Algorithm::RX_0);
    }
}

} // namespace


struct xmo_engine {
    xmrig::Algorithm algorithm;
    int   algo_id       = XMO_RX_0;
    bool  huge          = false;
    bool  full_mem      = true;
    bool  jit           = true;
    uint8_t *cache_mem  = nullptr;
    uint8_t *data_mem   = nullptr;
    size_t  cache_bytes = 0;
    size_t  data_bytes  = 0;
    randomx_cache   *cache   = nullptr;
    randomx_dataset *dataset = nullptr;
};


struct xmo_vm {
    randomx_vm *vm         = nullptr;
    xmrig::Algorithm algorithm;
    uint8_t *scratchpad    = nullptr;
    size_t   scratch_bytes = 0;
};


xmo_engine *xmo_engine_new(int algo, int flags, char *err, size_t errlen)
{
    auto *engine = new xmo_engine();

    engine->algo_id  = algo;
    engine->algorithm = toAlgorithm(algo);
    engine->huge     = (flags & 1) != 0;
    engine->full_mem = (flags & 4) != 0;
    engine->jit      = (flags & 8) != 0;

    // Select the per-coin RandomX configuration before touching any sizes.
    xmrig::RxAlgo::apply(engine->algorithm.id());
    randomx_set_optimized_dataset_init(algo == XMO_RX_XLA ? 0 : -1);
    randomx_set_huge_pages_jit((flags & 2) != 0);

    const int cache_flags = engine->jit ? RANDOMX_FLAG_JIT : RANDOMX_FLAG_DEFAULT;

    engine->cache_bytes = RANDOMX_CACHE_MAX_SIZE;
    engine->cache_mem   = mapPages(engine->cache_bytes, engine->huge, &engine->cache_bytes);
    if (!engine->cache_mem) {
        setError(err, errlen, "cannot allocate the RandomX cache");
        delete engine;

        return nullptr;
    }

    engine->cache = randomx_create_cache(static_cast<randomx_flags>(cache_flags), engine->cache_mem);
    if (!engine->cache) {
        engine->cache = randomx_create_cache(RANDOMX_FLAG_DEFAULT, engine->cache_mem);
    }

    if (!engine->cache) {
        setError(err, errlen, "randomx_create_cache failed");
        unmapPages(engine->cache_mem, engine->cache_bytes);
        delete engine;

        return nullptr;
    }

    if (engine->full_mem) {
        engine->data_bytes = RANDOMX_DATASET_MAX_SIZE;
        engine->data_mem   = mapPages(engine->data_bytes, engine->huge, &engine->data_bytes);
        if (!engine->data_mem) {
            setError(err, errlen, "cannot allocate the RandomX dataset");
            randomx_release_cache(engine->cache);
            unmapPages(engine->cache_mem, engine->cache_bytes);
            delete engine;

            return nullptr;
        }

        engine->dataset = randomx_create_dataset(engine->data_mem);
        if (!engine->dataset) {
            setError(err, errlen, "randomx_create_dataset failed");
            randomx_release_cache(engine->cache);
            unmapPages(engine->data_mem, engine->data_bytes);
            unmapPages(engine->cache_mem, engine->cache_bytes);
            delete engine;

            return nullptr;
        }
    }

    return engine;
}


void xmo_engine_free(xmo_engine *engine)
{
    if (!engine) {
        return;
    }

    if (engine->dataset) {
        randomx_release_dataset(engine->dataset);
    }
    if (engine->cache) {
        randomx_release_cache(engine->cache);
    }

    unmapPages(engine->data_mem, engine->data_bytes);
    unmapPages(engine->cache_mem, engine->cache_bytes);

    delete engine;
}


size_t xmo_engine_dataset_size(const xmo_engine *engine) { return engine ? engine->data_bytes : 0; }
size_t xmo_engine_cache_size(const xmo_engine *engine)   { return engine ? engine->cache_bytes : 0; }


size_t xmo_engine_huge_pages(const xmo_engine *engine)
{
    if (!engine) {
        return 0;
    }

    return engine->huge ? (engine->cache_bytes + engine->data_bytes) : 0;
}


size_t xmo_engine_total_memory(const xmo_engine *engine)
{
    if (!engine) {
        return 0;
    }

    return engine->cache_bytes + engine->data_bytes;
}


int xmo_engine_seed(xmo_engine *engine, const uint8_t *seed, size_t seed_len,
                    int threads, char *err, size_t errlen)
{
    if (!engine || !seed || seed_len == 0) {
        setError(err, errlen, "invalid seed");

        return -1;
    }

    randomx_init_cache(engine->cache, seed, seed_len);

    if (!engine->dataset) {
        return 0;
    }

    if (threads < 1) {
        threads = 1;
    }

    const unsigned long total = randomx_dataset_item_count();
    const unsigned long per   = total / static_cast<unsigned long>(threads);

    if (threads == 1) {
        randomx_init_dataset(engine->dataset, engine->cache, 0, total);

        return 0;
    }

    std::vector<std::thread> workers;
    workers.reserve(static_cast<size_t>(threads));

    for (int i = 0; i < threads; ++i) {
        const unsigned long start = per * static_cast<unsigned long>(i);
        const unsigned long count = (i == threads - 1) ? (total - start) : per;

        workers.emplace_back([engine, start, count]() {
            randomx_init_dataset(engine->dataset, engine->cache, start, count);
        });
    }

    for (auto &worker : workers) {
        worker.join();
    }

    return 0;
}


xmo_vm *xmo_vm_new(xmo_engine *engine, int flags, uint32_t numa_node,
                   char *err, size_t errlen)
{
    if (!engine) {
        setError(err, errlen, "no engine");

        return nullptr;
    }

    auto *result = new xmo_vm();
    result->algorithm = engine->algorithm;

    const bool huge = (flags & 1) != 0;
    result->scratchpad = mapPages(kScratchpad, huge, &result->scratch_bytes);
    if (!result->scratchpad) {
        setError(err, errlen, "cannot allocate the scratchpad");
        delete result;

        return nullptr;
    }

    int vm_flags = RANDOMX_FLAG_HARD_AES;
    if (engine->full_mem) {
        vm_flags |= RANDOMX_FLAG_FULL_MEM;
    }
    if (engine->jit) {
        vm_flags |= RANDOMX_FLAG_JIT;
    }

    result->vm = randomx_create_vm(static_cast<randomx_flags>(vm_flags),
                                   engine->cache, engine->dataset,
                                   result->scratchpad, numa_node);
    if (!result->vm) {
        setError(err, errlen, "randomx_create_vm failed");
        unmapPages(result->scratchpad, result->scratch_bytes);
        delete result;

        return nullptr;
    }

    return result;
}


void xmo_vm_free(xmo_vm *vm)
{
    if (!vm) {
        return;
    }

    if (vm->vm) {
        randomx_destroy_vm(vm->vm);
    }

    unmapPages(vm->scratchpad, vm->scratch_bytes);
    delete vm;
}


void xmo_hash(xmo_vm *vm, const uint8_t *blob, size_t len, uint8_t *out)
{
    randomx_calculate_hash(vm->vm, blob, len, out, vm->algorithm);
}


/* The pipeline state is fed to AES intrinsics with aligned 16-byte loads, so it
 * must live in aligned memory. Callers that cannot guarantee 64 bytes get a
 * bounce buffer instead of a general protection fault. */
static inline bool isAligned64(const void *p)
{
    return (reinterpret_cast<uintptr_t>(p) & 63) == 0;
}


void xmo_hash_first(xmo_vm *vm, const uint8_t *blob, size_t len, uint64_t *temp)
{
    if (isAligned64(temp)) {
        randomx_calculate_hash_first(vm->vm, *reinterpret_cast<uint64_t (*)[8]>(temp), blob, len, vm->algorithm);

        return;
    }

    uint64_t local[8] __attribute__((aligned(64))) = {};
    randomx_calculate_hash_first(vm->vm, *reinterpret_cast<uint64_t (*)[8]>(local), blob, len, vm->algorithm);
    std::memcpy(temp, local, sizeof(local));
}


void xmo_hash_next(xmo_vm *vm, uint64_t *temp, const uint8_t *blob, size_t len, uint8_t *out)
{
    if (isAligned64(temp)) {
        randomx_calculate_hash_next(vm->vm, *reinterpret_cast<uint64_t (*)[8]>(temp), blob, len, out, vm->algorithm);

        return;
    }

    // RandomX wants a 64-byte aligned staging block, so hash through a local
    // copy - and copy the *updated* state back, otherwise the next call would
    // start from the previous blob and every hash after the first one would be
    // wrong. (That is not theoretical: it produced one bad share in ~300
    // before it was found.)
    uint64_t local[8] __attribute__((aligned(64)));
    std::memcpy(local, temp, sizeof(local));
    randomx_calculate_hash_next(vm->vm, *reinterpret_cast<uint64_t (*)[8]>(local), blob, len, out, vm->algorithm);
    std::memcpy(temp, local, sizeof(local));
}


void xmo_commitment(const uint8_t *blob, size_t len, const uint8_t *hash_in, uint8_t *out)
{
    randomx_calculate_commitment(blob, len, hash_in, out);
}


void xmo_set_scratchpad_prefetch(int mode)        { randomx_set_scratchpad_prefetch_mode(mode); }
void xmo_set_huge_pages_jit(int enabled)          { randomx_set_huge_pages_jit(enabled != 0); }
void xmo_set_optimized_dataset_init(int value)    { randomx_set_optimized_dataset_init(value); }


const char *xmo_engine_name(void)
{
    return "RandomX (XMRig Ocean)";
}
