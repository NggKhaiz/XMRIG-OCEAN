# Which miner actually mines faster: C++, Rust, Go?

Short answer: **the C++ RandomX JIT wins, and not by a little.** This page
records what was measured and what was read, so the decision can be re-checked
instead of trusted.

- [1. Why language choice matters for RandomX](#1-why-language-choice-matters-for-randomx)
- [2. Measured on this hardware](#2-measured-on-this-hardware)
- [3. The candidates](#3-the-candidates)
- [4. Verdict](#4-verdict)
- [5. How to re-run the comparison](#5-how-to-re-run-the-comparison)

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

What would change this answer: a Rust/Go RandomX implementation with its own
JIT that matches the reference on the official test vectors. None exists today.
If one appears, the comparison in section 5 is the test to run.

---

## 5. How to re-run the comparison

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
