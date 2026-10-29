# Performance guide

Everything that influence the hashrate of this miner, in the order it matters.
Numbers marked **measured here** come from the CI sandbox this fork was
validated in (2 vCPU Xeon, AVX2, no huge pages available); numbers marked
*typical* are community/upstream ranges and must be verified on your own host
with `scripts/bench.sh`.

---

## 0. TL;DR checklist

```bash
# 1. build for this machine
./scripts/build-optimized.sh --clean

# 2. give it the memory it needs (root, once per boot)
sudo ./scripts/tune-linux.sh

# 3. measure before/after on the same host
./scripts/bench.sh --seconds 300 --hashes 200000

# 4. prove there is no dev fee
./scripts/verify-fee-free.sh
```

Startup log must show, in this order:

```
randomx  allocated 2336 MB (2080+256) huge pages 100% 1168/1168 +JIT
randomx  dataset ready (… ms)
cpu      READY threads N/N (N) huge pages 100%
msr      register values for "…" preset have been set successfully
```

If you see `huge pages 0%` or `FAILED TO APPLY MSR MOD`, you are leaving a large
amount of hashrate on the table — see sections 2 and 3.

---

## 1. What RandomX actually costs

RandomX (the algorithm behind Monero and most MoneroOcean routes) is designed to
be **memory latency bound**, not ALU bound:

* a 2080 MiB dataset, read at random 64-byte offsets, shared by all threads;
* a 2 MiB scratchpad per thread, filled with AES + integer ops, then accessed
  with random-ish addresses inside the JIT-compiled program;
* dataset initialisation once per seed (~3.5 days for Monero) or whenever the
  pool switches to a different RandomX variant.

Consequences, in order of impact:

1. **TLB coverage** (huge pages) — 2 GiB of 4 KiB pages is 524 288 TLB entries,
   far more than the CPU can cache. 2 MiB pages cut that by 512x, 1 GiB pages by
   262 144x.
2. **Hardware prefetcher behaviour** (MSR mod) — the dataset access pattern is
   random; the prefetcher wastes bandwidth and evicts useful lines. Disabling it
   is worth a lot on Zen and a bit less on Intel.
3. **Thread count vs. L3 cache** — one scratchpad (2 MiB) per thread must stay
   resident. Auto-config already targets physical cores with
   `L3 / 2 MiB` hashes; forcing SMT siblings only helps when the extra threads
   still fit in L3.
4. **NUMA placement** — on multi-socket hosts each node needs its own dataset
   (`randomx.numa`), otherwise half the threads read remote memory.
5. **CPU frequency / governor / thermals** — last, but zero cost to fix.

### Measured in this repository's sandbox

Host: 2 vCPU Xeon VM, 3.9 GiB RAM, no MSR access (the hypervisor rejects
`MSR 0x1a4`), 2 MiB huge pages reserved by `scripts/tune-linux.sh`.

| Configuration | RandomX hashrate | Dataset init |
|---|---|---|
| `-Ofast -maes` (upstream flags) | 1096 H/s (60 s avg, 4 samples) | 17.5 s |
| `-O3 -march=native -fno-plt` (this fork; LTO off) | 1091 H/s | 17.3–18.1 s |
| same, with 100 % huge pages (`huge pages 100% 1168/1168 +JIT`) | 1103 H/s peak, 1089 H/s avg | **14.9 s** |
| same, `--no-huge-pages` | not measurable here: a 2.3 GiB dataset on 4 KiB pages gets the process OOM-killed in a 3.9 GiB VM | — |
| same binary, RandomX **interpreter** instead of JIT | **180 H/s** | 15.0 s |

Three conclusions from that table:

* compiler flags are worth nothing on RandomX (JIT, see below);
* huge pages are worth a faster dataset init here and 10-30 % of hashrate on
  bare metal — on a small VM they are the difference between running and being
  OOM killed;
* the JIT is worth **6.1x** over the interpreter, which is why this project
  stays on C++ (see [ALTERNATIVES.md](ALTERNATIVES.md)).

**Compiler flags do not move RandomX**:
the hot loop is JIT-generated machine code produced at runtime from the same
RandomX sources, so `-march` has nothing to optimise there. Flags still help the
dataset initialiser and the CryptoNight/Argon2 C paths, so `build-optimized.sh`
keeps them, but do not expect a RandomX speedup from them.

The real gains are environmental (sections 2–4) and structural (section 6: no
donation switch).

---

## 2. Huge pages (biggest single lever)

| Page size | Typical RandomX gain vs 4 KiB |
|---|---|
| 2 MiB explicit (`huge-pages: true`) | +5 % … +20 % |
| 1 GiB explicit (`1gb-pages: auto`) | +1 % … +3 % on top of 2 MiB |
| Transparent huge pages (fallback) | +2 % … +8 %, less predictable |

`tune-linux.sh` reserves exactly what the RandomX dataset needs. Note that
XMRig itself also *tops up* `/proc/sys/vm/nr_hugepages` when it cannot get
enough pages (for example when a second miner or a benchmark runs while the
service is up). That is upstream behaviour and it is why
`./oneclick.sh bench` pauses the service first.

This fork improves the defaults:

* `huge-pages-jit` is **on** by default — the RandomX JIT code lives in huge
  pages too, which removes iTLB misses in the generated program;
* `1gb-pages` is **auto**: the miner reserves 1 GiB pages only when the kernel
  actually has some (`/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages`),
  otherwise it silently uses 2 MiB pages instead of logging an error;
* when huge pages are not fully allocated, the miner now prints an actionable
  warning instead of continuing silently.

Enable them once per boot:

```bash
sudo ./scripts/tune-linux.sh            # reserves ~2.4 GiB of 2 MiB pages
sudo ./scripts/tune-linux.sh --hugepages 1G   # better, needs contiguous free RAM
```

Verify:

```bash
grep Huge /proc/meminfo
# HugePages_Total:  1200
# HugePages_Free:   1200
# Hugepagesize:     2048 kB
```

The miner must run with `CAP_IPC_LOCK` (root, or
`setcap cap_ipc_lock,cap_sys_rawio,cap_sys_nice+ep build/xmrig`). Otherwise the
allocation fails and it falls back to transparent huge pages.

To make the reservation persistent, call the script from a systemd unit, e.g.
`/etc/systemd/system/xmrig-hugepages.service` (`Type=oneshot`,
`ExecStart=/opt/xmrig/scripts/tune-linux.sh`).

---

## 3. MSR mod ("HASHRATE WILL BE LOW")

`randomx.rdmsr` / `randomx.wrmsr` are already `true`. What is missing on most
systems is permission to use them:

```bash
sudo modprobe msr
ls -l /dev/cpu/0/msr           # must exist
sudo ./build/xmrig …           # start as root, or grant CAP_SYS_RAWIO
```

Intel preset: `MSR 0x1a4 = 0xf` (disable L2/L1 prefetchers).
AMD presets (Zen 1–5): `0xC0011020/21/22/2b` (prefetcher, DSM, commit unit).

Typical gain on Zen3/Zen4: **+5 % … +15 %**. On Intel it is smaller but still
measurable. The original values are saved at startup and restored on exit
(`RxMsr::destroy`).

`cache_qos` (Intel CAT) can help when several workloads share L3; it requires
explicit CPU affinity for every mining thread and is off by default.

---

## 4. CPU, BIOS and OS

| Item | Recommendation |
|---|---|
| SMT / HyperThreading | Leave enabled in BIOS, but do **not** mine on siblings unless `L3 / 2 MiB` allows it. Auto-config already avoids them for RandomX. |
| Frequency | `performance` governor, turbo enabled, C1E/C6 as high as stable. |
| RAM | For RandomX, memory latency beats bandwidth: 2 DIMMs per channel, XMP/EXPO on, Gear1 on Intel. |
| NUMA | Dual socket: keep `randomx.numa: true` (allocates one dataset per node). |
| Swappiness | `vm.swappiness=10`; never let the dataset be paged out. |
| KSM | Keep disabled — merging pages destroys latency. |
| THP | `always` is fine; `defrag=defer` avoids stalls. The tuning script sets both. |
| Priority | `cpu.priority: 5` (root) or `nice -n -20`, and `chrt -f 1` on dedicated rigs. This fork implements `setpriority()` on Linux (upstream ignores `cpu.priority` there). |
| Thermal | Sustained clocks matter more than peak; check `turbostat`/`sensors` after 10 minutes. |
| Windows | Disable Defender real-time scan for the miner directory, use the `WinRing0` driver (bundled) for MSR, set the process priority to High. |

The tune script covers governor, THP, swappiness, MSR module and huge pages in
one shot and prints a report with `--status`.

---

## 5. Build configuration

`cmake/tuning.cmake` adds:

| Option | Default | What it does |
|---|---|---|
| `XMRIG_NATIVE_OPT` | ON | `-march=native -mtune=native` (host-specific binary) |
| `WITH_LTO` | **OFF** | `-flto=auto`. Off by default: `-march` is safe, but GCC 12 LTO miscompiles CryptoNight (self-test fails). RandomX does not benefit anyway. |
| `WITH_EXTRA_OPT` | ON | `-fno-plt -falign-functions=32 -falign-loops=32` |
| `XMRIG_PGO` | off | `generate` / `use` profile-guided optimisation |

`./scripts/build-optimized.sh` wraps all of it:

```bash
./scripts/build-optimized.sh                 # Release, native, LTO, CPU only
./scripts/build-optimized.sh --portable      # baseline ISA, for other machines
./scripts/build-optimized.sh --pgo           # PGO: instrument, train 180 s, rebuild
./scripts/build-optimized.sh --all-backends  # keep OpenCL/CUDA
```

LTO is exposed as `--lto` for experimentation only. It was verified to break the
CryptoNight self-test in this tree (`thread #0 self-test failed` → CPU backend
disabled for `cn/*`), which is why it is off by default; if you enable it, run
`node run_tests.js --suite miner-integration` before mining.

PGO workflow (GCC): the script builds an instrumented binary, runs the offline
RandomX benchmark for `--pgo-seconds` (default 180 s, the process handles
SIGTERM cleanly so the profile is flushed), then rebuilds with
`-fprofile-use`. Expect a small gain (0–2 %); it is safe and free.

CPU-only builds (`--all-backends` not passed) disable OpenCL/CUDA/NVML/ADL.
This removes runtime dependencies and shaves startup time; CPU hashrate is
identical.

**Static binaries**: `--static` produces a fully static build for old
distributions. It disables `dlopen` of GPU drivers, which is fine for CPU-only.

---

## 6. Structure: this fork has no donation switch

Upstream XMRig donates 1 % of the *time*: every ~100 minutes the miner stops the
user's pool session and connects to the developer's pool for 1 minute. With
RandomX that is much more expensive than 1 %:

* a different pool means a different seed, so the **2 GiB dataset is rebuilt**
  (tens of seconds of one-time cost, all cores busy);
* all worker threads are destroyed and re-created, which also drops JIT-compiled
  VMs and re-faults the scratchpads;
* the nonce window is reset, so in-flight work is discarded;
* the pool session is re-established twice (TLS handshake, login, job).

In practice a 1 % donation costs **2–4 % of real hashrate** on RandomX, and more
on algorithm-switching pools. This fork removes the mechanism entirely
(`doc/ZERO_FEE.md`), so you keep that time plus the guaranteed 1 %.

For MoneroOcean specifically:

| Situation | Effect | Mitigation |
|---|---|---|
| Pool switches algorithm (profitability) | backend restart: new workers, new scratchpads, sometimes a new dataset | `memory-pool: true` (default) reuses scratchpad memory; `algo-min-time` in the config asks the pool to wait longer between switches |
| First start, no `algo-perf` yet | ~2 min calibration (10 algorithms × 10 s) | keep the generated `algo-perf` in `config.json`; use `--rebench-algo` only after hardware changes |
| New Monero seed | dataset re-init once | nothing to do, dataset memory is reused |
| Switching between RandomX variants (rx/0 ↔ rx/xla ↔ rx/arq) | cache + dataset re-init | prefer stable pools/chains, or accept a few seconds per switch |

`algo-min-time` is advertised to the pool at login; a value of `20`–`30` s is a
good compromise on a single rig, `0` lets the pool switch as fast as it wants.

---

## 7. Recommended configuration

`config/performance.json` in this repository is a ready-to-edit template:

```json
{
  "cpu": {
    "huge-pages": true,
    "huge-pages-jit": true,
    "memory-pool": true,
    "yield": false,
    "priority": 5,
    "max-threads-hint": 100,
    "asm": true
  },
  "randomx": {
    "mode": "auto",
    "rdmsr": true,
    "wrmsr": true,
    "numa": true,
    "scratchpad_prefetch_mode": 1
  },
  "donate-level": 0,
  "print-time": 60
}
```

Omitting `1gb-pages` means "auto": the miner uses 1 GiB pages when the kernel
has them, and 2 MiB pages otherwise. Setting it to `true` forces the attempt and
logs an error when the reservation is missing.

`scratchpad_prefetch_mode`: `1` (T0) is the best default on Zen and most Intel
parts; try `2` (NTA) and `3` if you want to squeeze a few tenths of a percent —
measure with `bench.sh`, the difference is small and CPU specific.

Thread tuning beyond auto-config:

```json
"cpu": {
    "rx": [[1, 0], [1, 2], [1, 4], [1, 6], [1, 8], [1, 10]]
}
```

one thread per **physical** core (affinity list from
`lscpu -e=cpu,core,cache`), no SMT siblings.

---

## 8. How to measure honestly

```bash
./scripts/bench.sh --seconds 300 --hashes 200000          # offline RandomX benchmark
```

Rules:

1. Same host, same binary, same thread count, same background load.
2. Ignore the first ~30 s after `dataset ready`; the benchmark needs a full
   60 s window before the 60 s average is valid (the script handles this).
3. Run each configuration at least twice; ±1 % noise is normal on a desktop,
   much less on a dedicated rig with fixed clocks.
4. Compare *shares per hour* on the pool as the final authority — hashrate is a
   proxy, rejected shares and switch overheads are not.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `huge pages 0%` at startup | not reserved / no permission | run `tune-linux.sh`, start as root or set capabilities |
| `FAILED TO APPLY MSR MOD` | no `/dev/cpu/*/msr` or no `CAP_SYS_RAWIO` | `modprobe msr`, run as root |
| `failed to allocate RandomX dataset, switching to slow mode` | not enough free RAM (needs ~2.4 GiB) | free memory, or use `"mode": "light"` (much slower, only for low-RAM boxes) |
| `not enough memory for RandomX dataset` | auto mode with < 2.4 GiB free | same as above |
| Hashrate far below reviews | SMT threads mining, thermal throttle, laptop power limit | check `cpu` READY line, `turbostat`, BIOS |
| Hashrate drops periodically | pool switching algorithms, or donation in an unpatched build | `algo-min-time`, use this fork |
| `no active pools, stop mining` | network / pool down | check `--verbose`, port, TLS |
| Windows: driver load error | WinRing0 blocked by Defender | allow the driver or run without MSR (slower) |
| Empty log file with `xmrig > log.txt` | upstream logging bug | fixed in this fork (`ConsoleLog` handles `UV_FILE`) |
