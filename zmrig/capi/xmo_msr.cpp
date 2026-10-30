/* ZMRIG (by @nggkhaiz) - RandomX memory-latency fix (the "MSR mod").
 *
 * RandomX is a memory-bound workload: the CPU's hardware prefetchers guess
 * wrong on the dataset and waste memory bandwidth. Disabling them (Intel:
 * MSR 0x1A4 bits 0-3, AMD: the Zen presets XMRig ships) is worth roughly
 * 5-15% on bare metal. It needs root and the msr kernel module, and it does
 * nothing inside a VM that does not pass the MSR through -- in that case we
 * say so once instead of pretending it worked.
 *
 * The presets below are the ones from src/crypto/rx/RxConfig.cpp in this tree,
 * so a zmrig run and an XMRig run leave the CPU in the same state.
 */

#include "xmo_randomx.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#ifdef __linux__
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#endif

namespace {

struct MsrItem {
    uint32_t reg;
    uint64_t value;
    uint64_t mask; // bits of `value` that are written; the rest is preserved
};

constexpr uint64_t kNoMask = ~0ULL;

/* --- presets, copied from RxConfig.cpp ---------------------------------- */

constexpr MsrItem kIntel[] = {
    { 0x1a4, 0xf, kNoMask },
};

constexpr MsrItem kRyzen17h[] = {
    { 0xC0011020, 0ULL, kNoMask },
    { 0xC0011021, 0x40ULL, ~0x20ULL },
    { 0xC0011022, 0x1510000ULL, kNoMask },
    { 0xC001102b, 0x2000cc16ULL, kNoMask },
};

constexpr MsrItem kRyzen19h[] = {
    { 0xC0011020, 0x0004480000000000ULL, kNoMask },
    { 0xC0011021, 0x001c000200000040ULL, ~0x20ULL },
    { 0xC0011022, 0xc000000401570000ULL, kNoMask },
    { 0xC001102b, 0x2000cc10ULL, kNoMask },
};

constexpr MsrItem kRyzen19hZen4[] = {
    { 0xC0011020, 0x0004400000000000ULL, kNoMask },
    { 0xC0011021, 0x0004000000000040ULL, ~0x20ULL },
    { 0xC0011022, 0x8680000401570000ULL, kNoMask },
    { 0xC001102b, 0x2040cc10ULL, kNoMask },
};

/* The Zen5 preset in RxConfig is identical to the Zen4 one; keeping the name
 * makes the log line match what a user reads in XMRig. */
constexpr MsrItem kRyzen1AhZen5[] = {
    { 0xC0011020, 0x0004400000000000ULL, kNoMask },
    { 0xC0011021, 0x0004000000000040ULL, ~0x20ULL },
    { 0xC0011022, 0x8680000401570000ULL, kNoMask },
    { 0xC001102b, 0x2040cc10ULL, kNoMask },
};

struct Preset {
    const char *name;
    const MsrItem *items;
    size_t count;
};

struct Saved {
    int cpu;
    uint32_t reg;
    uint64_t value;
};

std::vector<Saved> g_saved;
bool g_applied = false;

void say(char *report, size_t len, const char *text)
{
    if (!report || len == 0) {
        return;
    }

    std::snprintf(report, len, "%s", text);
}

/* CPU model + family from CPUID leaf 1, the same fields XMRig uses. */
bool cpuIdentity(char vendor[13], unsigned &family, unsigned &model)
{
    unsigned eax = 0, ebx = 0, ecx = 0, edx = 0;

#if defined(__x86_64__) || defined(__i386__)
    __asm__ __volatile__("cpuid"
                         : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                         : "a"(0), "c"(0));
    unsigned max_leaf = eax;

    __asm__ __volatile__("cpuid"
                         : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                         : "a"(0), "c"(0));
    std::memcpy(vendor + 0, &ebx, 4);
    std::memcpy(vendor + 4, &edx, 4);
    std::memcpy(vendor + 8, &ecx, 4);
    vendor[12] = '\0';

    if (max_leaf < 1) {
        return false;
    }

    __asm__ __volatile__("cpuid"
                         : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                         : "a"(1), "c"(0));

    family = ((eax >> 8) & 0xF) + ((eax >> 20) & 0xFF);
    model = ((eax >> 16) & 0xF) << 4 | ((eax >> 4) & 0xF);

    return true;
#else
    (void) vendor;
    (void) family;
    (void) model;

    return false;
#endif
}

Preset presetForCpu()
{
    char vendor[13] = { 0 };
    unsigned family = 0, model = 0;

    if (!cpuIdentity(vendor, family, model)) {
        return { "unsupported", nullptr, 0 };
    }

    if (std::strcmp(vendor, "GenuineIntel") == 0) {
        return { "intel", kIntel, sizeof(kIntel) / sizeof(kIntel[0]) };
    }

    if (std::strcmp(vendor, "AuthenticAMD") == 0) {
        switch (family) {
        case 0x17:
            return { "ryzen_17h", kRyzen17h, sizeof(kRyzen17h) / sizeof(kRyzen17h[0]) };
        case 0x19:
            if (model == 0x61 || model == 0x75) {
                return { "ryzen_19h_zen4", kRyzen19hZen4, sizeof(kRyzen19hZen4) / sizeof(kRyzen19hZen4[0]) };
            }

            return { "ryzen_19h", kRyzen19h, sizeof(kRyzen19h) / sizeof(kRyzen19h[0]) };
        case 0x1a:
            return { "ryzen_1Ah_zen5", kRyzen1AhZen5, sizeof(kRyzen1AhZen5) / sizeof(kRyzen1AhZen5[0]) };
        default:
            break;
        }
    }

    return { "none", nullptr, 0 };
}

int openMsr(int cpu)
{
    char path[64];
    std::snprintf(path, sizeof(path), "/dev/cpu/%d/msr", cpu);

    return ::open(path, O_RDWR);
}

bool readMsr(int fd, uint32_t reg, uint64_t &value)
{
    return ::pread(fd, &value, sizeof(value), static_cast<off_t>(reg)) == static_cast<ssize_t>(sizeof(value));
}

bool writeMsr(int fd, uint32_t reg, uint64_t value)
{
    return ::pwrite(fd, &value, sizeof(value), static_cast<off_t>(reg)) == static_cast<ssize_t>(sizeof(value));
}

} // namespace


extern "C" int xmo_msr_apply(int save, char *report, size_t report_len)
{
#ifndef __linux__
    say(report, report_len, "unsupported: not Linux");
    (void) save;

    return 1;
#else
    const Preset preset = presetForCpu();

    if (!preset.items || preset.count == 0) {
        char text[96];
        std::snprintf(text, sizeof(text), "unsupported: no preset for this CPU (%s)", preset.name);
        say(report, report_len, text);

        return 1;
    }

    if (::geteuid() != 0) {
        say(report, report_len, "needs root (the msr device is 0600)");

        return 1;
    }

    const long cpus = ::sysconf(_SC_NPROCESSORS_CONF);
    int applied = 0, failed = 0;
    int last_errno = 0;

    for (long cpu = 0; cpu < cpus; ++cpu) {
        const int fd = openMsr(static_cast<int>(cpu));
        if (fd < 0) {
            ++failed;
            last_errno = errno;

            continue;
        }

        bool ok = true;

        for (size_t i = 0; i < preset.count; ++i) {
            uint64_t old = 0;

            if (!readMsr(fd, preset.items[i].reg, old)) {
                ok = false;
                last_errno = errno;

                break;
            }

            const uint64_t next = (old & ~preset.items[i].mask) | (preset.items[i].value & preset.items[i].mask);
            if (next == old) {
                continue;
            }

            if (!writeMsr(fd, preset.items[i].reg, next)) {
                ok = false;
                last_errno = errno;

                break;
            }

            if (save) {
                g_saved.push_back({ static_cast<int>(cpu), preset.items[i].reg, old });
            }
        }

        ::close(fd);

        if (ok) {
            ++applied;
        } else {
            ++failed;
        }
    }

    if (applied == 0) {
        char text[160];
        /* EINVAL from an MSR the hypervisor does not expose is the normal case
         * inside a VM, not a bug: say it plainly. */
        std::snprintf(text, sizeof(text),
                      "%s preset rejected by the kernel (%s) - normal inside a VM without MSR passthrough",
                      preset.name, std::strerror(last_errno ? last_errno : EINVAL));
        say(report, report_len, text);

        return 1;
    }

    g_applied = true;

    char text[160];
    if (failed == 0) {
        std::snprintf(text, sizeof(text), "%s preset applied to %d CPU(s)", preset.name, applied);
    } else {
        std::snprintf(text, sizeof(text), "%s preset applied to %d CPU(s), %d failed", preset.name, applied, failed);
    }
    say(report, report_len, text);

    return failed == 0 ? 0 : 2;
#endif
}


extern "C" int xmo_msr_restore(char *report, size_t report_len)
{
#ifndef __linux__
    (void) report;
    (void) report_len;

    return 0;
#else
    if (!g_applied) {
        return 0;
    }

    int restored = 0;

    for (const Saved &item : g_saved) {
        const int fd = openMsr(item.cpu);
        if (fd < 0) {
            continue;
        }

        if (writeMsr(fd, item.reg, item.value)) {
            ++restored;
        }

        ::close(fd);
    }

    g_saved.clear();
    g_applied = false;

    char text[96];
    std::snprintf(text, sizeof(text), "restored %d MSR value(s)", restored);
    say(report, report_len, text);

    return 0;
#endif
}


extern "C" int xmo_msr_probe(char *report, size_t report_len)
{
#ifndef __linux__
    say(report, report_len, "unsupported: not Linux");

    return 1;
#else
    const Preset preset = presetForCpu();

    if (!preset.items || preset.count == 0) {
        char text[96];
        std::snprintf(text, sizeof(text), "no preset for this CPU (%s)", preset.name);
        say(report, report_len, text);

        return 1;
    }

    const int fd = openMsr(0);
    if (fd < 0) {
        char text[160];
        if (errno == EACCES) {
            std::snprintf(text, sizeof(text), "%s preset; reading /dev/cpu/0/msr needs root", preset.name);
        } else {
            std::snprintf(text, sizeof(text), "%s preset, but /dev/cpu/0/msr is not available (%s)", preset.name, std::strerror(errno));
        }
        say(report, report_len, text);

        return 1;
    }

    uint64_t old = 0;
    const bool readable = readMsr(fd, preset.items[0].reg, old);
    const int read_errno = errno;
    ::close(fd);

    char text[160];
    if (readable) {
        std::snprintf(text, sizeof(text), "%s preset available (0x%x = 0x%llx)%s",
                      preset.name, preset.items[0].reg,
                      static_cast<unsigned long long>(old),
                      ::geteuid() == 0 ? "" : ", but writing needs root");
    } else {
        std::snprintf(text, sizeof(text), "%s preset, but the kernel refuses the read (%s) - a VM without MSR passthrough",
                      preset.name, std::strerror(read_errno));
    }
    say(report, report_len, text);

    return readable ? 0 : 1;
#endif
}
