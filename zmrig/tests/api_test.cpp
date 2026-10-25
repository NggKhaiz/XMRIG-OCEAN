/* Validates the hash engine C API against the vectors this repository already
 * trusts (see tests/hash/main.cpp). Build with zmrig/tests/run.sh. */
#include "../capi/xmo_randomx.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int failures = 0;

static void check(const char *name, const uint8_t *got, const uint8_t *want)
{
    if (std::memcmp(got, want, 32) == 0) {
        std::printf("PASS %s\n", name);
        return;
    }

    std::printf("FAIL %s\n  got  ", name);
    for (int i = 0; i < 32; ++i) std::printf("%02x", got[i]);
    std::printf("\n  want ");
    for (int i = 0; i < 32; ++i) std::printf("%02x", want[i]);
    std::printf("\n");
    ++failures;
}

static void unhex(const char *hex, uint8_t *out)
{
    for (int i = 0; i < 32; ++i) {
        unsigned v = 0;
        std::sscanf(hex + i * 2, "%2x", &v);
        out[i] = static_cast<uint8_t>(v);
    }
}

int main()
{
    char err[256] = {};

    const std::string seed  = "xmrig-mo-check-hashes seed";
    const std::string inA   = "xmrig-mo-check-hashes input A";
    const std::string inB   = "xmrig-mo-check-hashes input B";
    const std::string inC   = "xmrig-mo-check-hashes input C";

    uint8_t wantA[32];
    unhex("1833ff322e60dad7d6885bcd5e0844ec8e4808a47d8d354806668f0c241a6af5", wantA);

    std::printf("engine: %s\n", xmo_engine_name());

    /* --- light mode (cache only), the fastest way to validate the API --- */
    xmo_engine *light = xmo_engine_new(XMO_RX_0, /*jit*/ 8, err, sizeof(err));
    if (!light) {
        std::printf("FAIL engine_new: %s\n", err);
        return 1;
    }

    if (xmo_engine_seed(light, reinterpret_cast<const uint8_t *>(seed.data()), seed.size(), 1, err, sizeof(err)) != 0) {
        std::printf("FAIL seed: %s\n", err);
        return 1;
    }

    xmo_vm *vm = xmo_vm_new(light, 0, 0, err, sizeof(err));
    if (!vm) {
        std::printf("FAIL vm_new: %s\n", err);
        return 1;
    }

    uint8_t outA[32] = {}, outB[32] = {};
    xmo_hash(vm, reinterpret_cast<const uint8_t *>(inA.data()), inA.size(), outA);
    check("rx/0 light hash A", outA, wantA);

    xmo_hash(vm, reinterpret_cast<const uint8_t *>(inB.data()), inB.size(), outB);

    /* RandomX pipelining: first() prepares blob A, and each next() returns the
     * hash of the previous blob (same contract as tests/hash/main.cpp). */
    uint64_t temp[8] = {};
    uint8_t nextA[32] = {}, nextB[32] = {};
    xmo_hash_first(vm, reinterpret_cast<const uint8_t *>(inA.data()), inA.size(), temp);
    xmo_hash_next(vm, temp, reinterpret_cast<const uint8_t *>(inB.data()), inB.size(), nextA);
    xmo_hash_next(vm, temp, reinterpret_cast<const uint8_t *>(inC.data()), inC.size(), nextB);
    check("rx/0 light first/next A", nextA, outA);
    check("rx/0 light first/next B", nextB, outB);

    xmo_vm_free(vm);
    xmo_engine_free(light);

    /* --- full memory mode equals light mode, and the dataset is 2 GiB ---
     * Needs 2.25 GiB, so it only runs when the machine has reserved huge pages
     * (or plenty of RAM); otherwise we would OOM the box, not test the code. */
    unsigned long hp = 0;
    if (FILE *f = std::fopen("/proc/sys/vm/nr_hugepages", "r")) {
        if (std::fscanf(f, "%lu", &hp) != 1) hp = 0;
        std::fclose(f);
    }

    if (hp < 1152) {
        std::printf("SKIP full-memory test (only %lu huge pages of the 1152 needed)\n", hp);
        std::printf(failures == 0 ? "\nall API checks passed\n" : "\n%d FAILURES\n", failures);

        return failures == 0 ? 0 : 1;
    }

    xmo_engine *full = xmo_engine_new(XMO_RX_0, /*huge|jit|full*/ 13, err, sizeof(err));
    if (!full) {
        std::printf("FAIL engine_new full: %s\n", err);
        return 1;
    }

    std::printf("dataset bytes: %zu (items %lu)\n", xmo_engine_dataset_size(full),
                static_cast<unsigned long>(xmo_engine_dataset_size(full) / 2048));

    /* 2 GiB base dataset + 32 MiB extra used by the alternate coin configs */
    if (xmo_engine_dataset_size(full) != 2181038080ULL) {
        std::printf("FAIL dataset size\n");
        ++failures;
    }

    if (xmo_engine_seed(full, reinterpret_cast<const uint8_t *>(seed.data()), seed.size(), 2, err, sizeof(err)) != 0) {
        std::printf("FAIL seed full: %s\n", err);
        return 1;
    }

    xmo_vm *fvm = xmo_vm_new(full, 0, 0, err, sizeof(err));
    if (!fvm) {
        std::printf("FAIL vm_new full: %s\n", err);
        return 1;
    }

    uint8_t fA[32] = {};
    xmo_hash(fvm, reinterpret_cast<const uint8_t *>(inA.data()), inA.size(), fA);
    check("rx/0 full-mem hash A", fA, wantA);

    /* commitments are used by Monero's v2 proof of work */
    uint8_t com[32] = {};
    xmo_commitment(reinterpret_cast<const uint8_t *>(inC.data()), inC.size(), fA, com);
    std::printf("commitment A: ");
    for (int i = 0; i < 32; ++i) std::printf("%02x", com[i]);
    std::printf("\n");

    xmo_vm_free(fvm);
    xmo_engine_free(full);

    std::printf(failures == 0 ? "\nall API checks passed\n" : "\n%d FAILURES\n", failures);

    return failures == 0 ? 0 : 1;
}
