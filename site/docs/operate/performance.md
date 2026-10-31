---
title: Performance
description: What actually changes hashrate on a CPU, what does not, and how to measure it without fooling yourself.
image: https://nggkhaiz.github.io/ZMRIG/img/og-en.png
---

# Performance

RandomX is a memory-bound proof of work: the hash loop reads a 2 GiB dataset in
a random order. Almost everything that matters follows from that one sentence.

## The three levers that matter

**Huge pages.** The largest and most obvious gain. A 4 KiB page size makes the
dataset walk a TLB miss every few accesses.

```bash
echo 1234 | sudo tee /proc/sys/vm/nr_hugepages    # ~2.4 GiB of 2 MiB pages
grep HugePages_ /proc/meminfo
```

The installer does this and sets `LimitMEMLOCK=infinity` in the unit. To check
the miner got them: the startup log prints `huge pages 2336 MB`, and the API
reports `"hugepages": [1168, 1168]` (granted / needed).

:::warning Measuring without huge pages
Once 1234 pages are reserved, only about 1.2 GB of ordinary RAM is left. Running
`--no-huge-pages` then gets the process OOM-killed (exit 137), because a second
2 GiB dataset does not fit. Set `nr_hugepages` to 0 before measuring that case,
and remember to put it back.
:::

**Fast or light mode.** `fast` builds one 2 GiB dataset shared by every thread.
`light` keeps a 256 MiB cache and rebuilds the dataset per hash: 76 H/s against
814 H/s on the same machine. Light mode exists for a VPS that cannot give 2 GiB,
not as a power-saving option.

**Threads.** One per physical core, two per core only when SMT helps: on the test
host, two threads on two vCPUs gave 814 H/s and one thread gave 408 H/s, which is
linear. SMT usually adds 5–15 % hashrate for 30–40 % more power, which is why the
`watt` profile drops it.

## The two that do not

- **Scratchpad prefetch mode** (0/1/2/3): 823, 814, 823, 814 H/s — inside noise.
  The default (1) stays.
- **Affinity** on a 2 vCPU machine: identical. It matters on a many-core box with
  an uneven L3, which is a different measurement.

Anything advertised as a large speed-up that is not huge pages, dataset mode or
thread count should be measured before it is believed.

## Measured

2 vCPU Xeon at 2.60 GHz, 3.9 GiB RAM, 1234 × 2 MiB huge pages, algorithm `rx/0`,
one run per configuration.

| Configuration | Hashrate | Ratio |
| --- | ---: | ---: |
| default: 2 threads, huge pages, prefetch 1 | 814 H/s | 100 % |
| `--no-huge-pages` | 634 H/s | 78 % |
| `--mode light` | 76 H/s | 9 % |
| `-t 1` | 408 H/s | 50 % |
| `--scratchpad-prefetch=0` | 823 H/s | 101 % (noise) |
| `--scratchpad-prefetch=2` | 823 H/s | 101 % (noise) |
| `--no-affinity` | 814 H/s | 100 % (noise) |

The same binary on the same host in a quieter session measured **1008–1103 H/s**.
That 20–25 % spread is why absolute numbers in documentation are close to
useless, and why the ratios above are the useful part.

C++ engine on the same host, for reference: **1075.7 H/s**. The gap to the Zig
engine is smaller than the gap between two runs.

## Measuring it yourself

```bash
zmrig --bench=20000      # fixed seed, fixed blob, dataset build excluded
zmrig --report --power 45   # 10 s warm-up + 15 s window, prints a code
sudo ./oneclick.sh bench    # stops the service first, then measures
```

Rules that make a measurement mean something:

1. **Stop the miner first.** A running miner holds the huge pages; the benchmark
   then allocates in ordinary memory and reports about 20 % low.
2. **Measure the machine you care about.** Absolute hashrate is a property of the
   host, not of the binary.
3. **Run each configuration twice.** Under 2 % is noise.

The full table, with the dates and the caveats, is in
[Benchmarks](/docs/reference/benchmarks).
