# Benchmarks

Reproducible numbers, with the command that produced them. Read the caveats:
absolute hashrate on a shared vCPU moves with the host, so the useful signal is
the ratio between configurations measured back to back.

## Validation host

| | |
|---|---|
| CPU | Intel Xeon @ 2.60 GHz, 2 vCPU visible (1 physical core, SMT) |
| L3 | 54 MB (reported), 1234 huge pages of 2 MiB reserved |
| RAM | 3.9 GiB |
| Kernel | Linux, `HugePages_Total: 1234` |
| Binary | `zmrig 6.28.0-mo11`, built with `ZIG=zig ./zmrig/build.sh --jobs 2` (`-march=native`) |
| Algorithm | `rx/0`, mode `fast` unless stated |

## Method

```bash
./zmrig/out/zmrig --bench=20000        # 20 000 hashes, seed 00112233…
./zmrig/out/zmrig --report             # 10 s warm-up + 15 s window, prints a code
```

`--bench` stops at the hash count or after 180 s. Dataset construction (15–25 s)
happens before the timer starts. The miner must not be running while measuring:
it holds the reserved huge pages, and the benchmark would then allocate the
dataset in normal pages (measured 20 % lower) or be OOM-killed.

## Results

### 2026-10-26, one run per configuration

| Configuration | Hashrate | Ratio | Note |
|---|---:|---:|---|
| default (2 threads, huge pages, prefetch 1) | 814 H/s | 100 % | reference |
| `--no-huge-pages` | 634 H/s | 78 % | pool released with `echo 0 > nr_hugepages` first |
| `--mode light` | 76 H/s | 9 % | 256 MiB cache, no dataset |
| `-t 1` | 408 H/s | 50 % | linear scaling on this host |
| `--scratchpad-prefetch=0` | 823 H/s | 101 % | within noise |
| `--scratchpad-prefetch=2` | 823 H/s | 101 % | within noise |
| `--scratchpad-prefetch=3` | 814 H/s | 100 % | within noise |
| `--no-affinity` | 814 H/s | 100 % | 2 vCPU, nothing to pin |

### Same binary, other sessions on the same host

| Session | Hashrate | Note |
|---|---:|---|
| earlier, idle host | 1008–1103 H/s | `--bench=20000 -t 2`, two runs |
| earlier, C++ frontend | 1075.7 H/s | same engine, same host |
| today | 814–845 H/s | host appears busier; ratios unchanged |

This 20–25 % spread between sessions is the reason the documentation never
quotes a single absolute number as a target. Measure your own machine.

### What did **not** help

- Scratchpad prefetch mode: 0/1/2/3 differ by <1.5 %, i.e. noise.
- Affinity: no effect with 2 vCPU.
- `--no-optimized-init`: changes dataset build time only.

## Memory behaviour worth knowing

With 1234 huge pages reserved, `--no-huge-pages` cannot allocate the 2 GiB
dataset and the kernel kills the process:

```
Killed  ./zmrig/out/zmrig --bench=2000 --no-huge-pages   # exit 137
```

Release the pool before comparing that configuration:

```bash
echo 0    | sudo tee /proc/sys/vm/nr_hugepages
echo 1234 | sudo tee /proc/sys/vm/nr_hugepages   # restore afterwards
```

## Seeding time

| Mode | Dataset ready |
|---|---:|
| `fast` (2 GiB) | 15.2–24.0 s |
| `light` (256 MiB cache) | ~0.6 s |

`--report` therefore takes ~25–30 s end to end: dataset + 10 s warm-up + 15 s
measurement + one 250 ms power sample.

## Network suite

```
./zmrig/tests/net.sh --soak
29 passed, 0 failed, 0 skipped
```

Logs: `/tmp/zmrig-net.XXXXXX/`. The suite runs in `--mode light` (50–70 H/s) so
it does not need the 2 GiB dataset.
