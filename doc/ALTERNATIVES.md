# Which miner actually mines faster: C++, Rust, Go?

Short answer: **the C++ RandomX JIT wins, and not by a little.** This page
records what was measured and what was read, so the decision can be re-checked
instead of trusted.

- [1. Why language choice matters for RandomX](#1-why-language-choice-matters-for-randomx)
- [2. Measured on this hardware](#2-measured-on-this-hardware)
- [3. The candidates](#3-the-candidates)
- [4. Verdict](#4-verdict)
- [5. What a "high-performance rewrite" can and cannot buy](#5-what-a-high-performance-rewrite-can-and-cannot-buy)
- [6. How to re-run the comparison](#6-how-to-re-run-the-comparison)

---

## 1. Why language choice matters for RandomX

RandomX does not execute a fixed inner loop that a compiler can optimise. It
**generates a random program for every hash** and executes it. The throughput of
a RandomX miner is therefore decided by how fast that freshly generated program
can run:

| Execution model | What it is | Relative speed |
|---|---|---|
| **JIT compilation** | generate native machine code for each program, then run it | 1x (baseline) |
| **Interpreter** | walk a bytecode/IR representation in a language loop | 4-10x slower |

Only a handful of implementations ship a JIT: the reference C++ (used by XMRig),
and a few closed-source miners that embed the same reference code. A pure Rust
or pure Go implementation has to interpret, and the RandomX reference README
says so explicitly:

> "RandomX currently includes a JIT compiler for x86-64, ARM64 and RISCV64.
> Other architectures have to use the portable interpreter, which is much
> slower." — [tevador/RandomX](https://github.com/tevador/RandomX)

It is also why a Rust/Go rewrite here would be a downgrade, not an
optimisation: the hashing work is not in our code, it is in RandomX.

---

## 2. Measured on this hardware

Both numbers come from **this repository, this machine** (2 vCPU Xeon VM,
2 MiB huge pages, 2 threads):

| RandomX back end | Hashrate | Notes |
|---|---|---|
| JIT (normal XMRig build) | **1103 H/s** | `./scripts/bench.sh` |
| Portable interpreter, same code and same memory | **180 H/s** | same binary with `RANDOMX_FLAG_JIT` removed |

**The JIT is 6.1x faster.** A from-scratch Rust or Go implementation can at best
approach the interpreter number, because it does not have the reference JIT.
That gap is far larger than any difference compiler flags, thread layout or
memory tuning can produce (those are worth 10-30 % in total, see
[PERFORMANCE.md](PERFORMANCE.md)).

---

## 3. The candidates

Everything below was checked against the project's own README via the GitHub API
in October 2026.

### C++ / XMRig family — **chosen**

| Project | Verdict |
|---|---|
| **XMRig** (this fork) | Reference RandomX JIT, all CPU algorithms, MoneroOcean algo switching, MSR + huge page handling. Fastest available. |
| **xmrig-mo** | The MoneroOcean fork this repository is based on. Same speed; upstream still ships the 1 % donation logic. |
| **GxMiner** (Go) | "core part … not fully open-sourcing"; its `go-randomx` is **cgo bindings to reference RandomX v1.2.1**, i.e. the same C++ core. It cannot be faster than XMRig, it is older, and half of it is closed source. |
| **SRBMiner-Multi / lolMiner** | Closed source. Their advantage is GPUs; for CPU RandomX they embed the reference implementation. No reason to move. |
| **xmr-stak** | Abandoned (2019), CryptoNight era, no RandomX v2 / MoneroOcean switching. |

### Rust

| Project | Verdict |
|---|---|
| **Ragnaroek/mithril** | The most visible "pure Rust Monero miner". Its own checklist says *"RandomX update (interpreter mode)"*, and the author writes *"Fast: should be as fast as the C-implementations (I want to say that, but I currently cannot prove it)"*. Interpreter only ⇒ the 180 H/s column above. |
| **tari-project/randomx-rs** | Rust *bindings* to the reference C++ library. Same speed as XMRig, but a binding does not mine by itself — it is a library, not a miner. |
| **uzi-miner** (Ziesha) | Single-coin miner for Ziesha, not Monero/MoneroOcean. |

### Go

| Project | Verdict |
|---|---|
| **opd-ai/go-randomx** | Pure Go, and its README carries a warning: *"hash outputs do not yet match the official RandomX reference implementation … DO NOT use for production blockchain validation or mining"*. Disqualified on correctness, before speed. |
| **mining-pool/go-randomx** | cgo bindings to the reference C++ library — the same core we already use, wrapped in Go. |
| **c0mm4nd/GxMiner** | See above: wrapper + closed source core. |
| **cryptonote-social/csminer** | Explicitly designed for *"set it and forget it"* background mining that keeps the desktop responsive, not for maximum hashrate; it wraps the reference library. |

---

## 4. Verdict

1. **Keep this C++ miner.** It runs the reference RandomX JIT, which is 6.1x
   faster than the interpreter on the hardware used for validation, and no
   Rust/Go project ships a competing JIT.
2. **Rust and Go are still useful here** — just not in the hash loop:
   - a stratum proxy / dashboard / REST collector in Go or Rust is a fine idea;
   - they are not part of this binary, and moving bytes on the network costs
     microseconds while a single hash costs ~2 ms on this CPU.
3. **The one thing that beat us was not another language** — it was removing the
   donation switch, fixing the memory defaults, and making huge pages + MSR
   actually apply. That is what this fork changed (see
   [ZERO_FEE.md](ZERO_FEE.md) and [PERFORMANCE.md](PERFORMANCE.md)).
4. **A fast-language frontend is still worth having**, because it removes the
   C++ build dependency and the libuv/OpenSSL/hwloc surface without touching the
   hash loop. That is `zmrig/`: 1084–1089 H/s installed, same as the C++
   frontend, built with a single `g++`+`zig` toolchain. See
   [../zmrig/README.md](../zmrig/README.md).

What would change this answer: a Rust/Go RandomX implementation with its own
JIT that matches the reference on the official test vectors. None exists today.
If one appears, the comparison in section 5 is the test to run.

---

## 5. What a "high-performance rewrite" can and cannot buy

A common proposal is a three-layer "supreme" miner: a Zig host controller, a
hand-written NASM RandomX core for the CPU and CUDA/PTX for the GPU. It was
evaluated against measurements on this machine, layer by layer.

### Layer 1 — Zig host controller: do it, but it buys latency, not hashrate

Delivered in `zmrig/` (see [../zmrig/README.md](../zmrig/README.md)). What the
proposal promises and what actually happens:

| promise | reality |
| --- | --- |
| zero allocation in the mining loop | done: fixed buffers, the only allocator traffic is once per job (JSON parse into an arena that is reset, never freed) |
| protocol/constants computed at compile time (comptime) | done: algorithm table, nonce offsets, the share target arithmetic and the JSON field names are compile-time |
| epoll / io_uring for nanosecond job delivery | **not done, deliberately.** A pool sends ~2.5 messages/s per connection; a `read()` on a blocking socket costs ~2 µs, and dataset re-init for a new seed costs 15 000 000 µs. The previous deadline-driven non-blocking reader also broke TLS record framing, which is why the reader is blocking and the 180 s silence timeout is a second thread calling `shutdown(2)` |
| lower stale-share rate | the dominant term is *when the job reaches the worker*, not how the frontend reads it: on a real pool, job propagation is milliseconds while a share takes ~0.4 s to find at 1000 H/s |

Measured result: the Zig frontend reaches 1084–1089 H/s on the same engine where
the C++ frontend reaches 1075.7 H/s — a difference inside run-to-run noise, which
is exactly the point: **the frontend is not on the critical path.**

### Layer 2 — hand-written NASM CPU core: already there, and it is called the JIT

RandomX does not run a fixed inner loop; it *generates a random program for
every hash* and executes it. The optimised assembly already exists:

* `src/crypto/randomx/jit_compiler_x86_static.S` — hand-written assembly for the
  fixed parts of the VM (prologue, register init, interp loop, scratchpad ops);
* `jit_compiler_x86.cpp` — emits the per-hash program, chooses AES/VAES and
  AVX-512 encodings for the CPU it runs on, and keeps VM state in registers.

`zmrig` links exactly that code, so "write the core by hand in NASM" is what we
already run. The alternative — a portable interpreter, which is what a from-
scratch Rust/Go/NASM rewrite effectively is — measured **178 H/s versus
1090 H/s**, i.e. 6.1x slower. Writing a second JIT that beats the reference one
on Monero's own consensus code is a research project, not a weekend rewrite.

Two claims from the proposal that cannot work:

* *"never spill to RAM, keep the hash state in zmm0–zmm31"* — RandomX programs
  address a 2 MiB scratchpad by design; the register allocation is decided by
  the JIT per generated program, and the ISA mix (AES rounds + integer ops) is
  fixed by the algorithm's specification, not by the frontend.
* *"zero cache misses"* — the whole point of a memory-hard PoW is that the hash
  streams through 2 MiB per thread with deliberate latency. Huge pages and
  prefetch distance are the levers that exist, and both are already on
  (2336 MB in 2 MiB pages, `RX_MSR`/prefetch tuned), measured at 1103 H/s peak
  versus 1091 H/s without them.

### Layer 3 — CUDA/PTX GPU core: not applicable to Monero

RandomX was designed to be hostile to GPUs and ASICs: 2 MiB of scratchpad per
thread, latency-bound random reads, and a JIT that changes with every seed. There
is no GPU miner for Monero worth running, and no amount of PTX tuning changes
that. The Ethash/ProgPoW techniques in the proposal (coalesced access, shared
memory bank layout, occupancy) belong to memory-bandwidth algorithms, not to
this one. This repository's GPU backends are for CryptoNight variants and are
untouched by the RandomX path.

### Profiling tools named in the proposal

`VTune`, `uProf`, `Nsight` and `llvm-mca` are the right tools for a
compute-bound kernel; they were not available in the validation environment
(no MSR access, no GPU, no profilers), so every number above comes from A/B
benchmarks of the real miner (`--bench`, `scripts/bench.sh`, identical huge-page
and thread settings, 60 s column). The conclusion they support is simple:
**at 1090 H/s on hardware whose reference JIT reaches 1090 H/s, the hash loop
has no headroom left; the remaining wins are memory configuration, thread
placement and not wasting CPU on donations.**

---

## 6. How to re-run the comparison

Any miner can be compared on the same hardware as long as the measurement is
fair:

```bash
# 1. this fork
./scripts/bench.sh --seconds 180

# 2. another xmrig-compatible miner (same window size!)
/path/to/other/miner --bench=1M --print-time=10

# 3. a miner without a built-in benchmark: mine the same pool, same difficulty,
#    for the same duration and compare accepted shares * average difficulty
```

Rules that matter:

- compare the **60 s column**, not the first 10 s sample (dataset warm-up);
- keep huge pages and MSR identical for both binaries, otherwise you are
  measuring the environment, not the miner;
- run each binary at least twice — ±1 % noise is normal;
- pin `--cpu-max-threads-hint` identically for both.

A miner that reports 1100 H/s on a machine where the reference JIT reaches
1100 H/s has nothing left to gain: the remaining headroom is memory and
scheduling, not code.
