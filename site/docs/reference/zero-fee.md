---
title: Zero fee, verified
description: What a developer fee costs on RandomX, what was removed in this tree, and the commands that prove the binary contains no second pool and no wallet.
---

# Zero fee, verified

This build mines **100 % for the pool and wallet you configure**. No developer
fee, no time slicing, no second stratum session, no hidden wallet.

The claim is worth nothing without a way to check it, so the checking comes
first.

```bash
./scripts/verify-fee-free.sh                 # source + binary audit
./scripts/verify-fee-free.sh --source-only   # no binary needed
```

The script asserts six things:

1. Both donation constants are `0`.
2. `DonateStrategy` is absent from the tree and from `CMakeLists.txt`.
3. No wallet address and no donation hostname exist under `src/`.
4. `Network` has no donation plumbing.
5. The built binary contains no developer wallet and no donation endpoint.
6. The binary reports `DONATE 0%` even when started with `--donate-level=9`.

Manual equivalents:

```bash
strings build/xmrig | grep -Ei 'donate\.|moneroocean\.stream|^[48][1-9A-HJ-NP-Za-km-z]{95}$'
# -> nothing

./build/xmrig --dry-run --url pool.example.com:3333 --user TEST --donate-level=9 | grep DONATE
# -> DONATE       0% (fee-free build)

curl -s http://127.0.0.1:18080/2/summary | jq .miner.donate_level
# -> 0
```

At runtime the log never prints `dev donate started`, and the HTTP API reports
`"donate_level": 0`.

## What upstream does

Upstream XMRig keeps the fee in `src/net/strategies/DonateStrategy.cpp`:
`Pools::donateLevel()` returns `donate-level` (default 1, minimum 1), and
`Network` runs a second strategy that, roughly every 100 minutes, pauses your
pool for one minute and connects to a developer pool
(`m_idleTime = (100 - level) * 60 s`, `m_donateTime = level * 60 s`). The
donation pool receives the hashes.

In the MoneroOcean-flavoured tree this fork descends from, that endpoint was
`xmrig.moneroocean.stream:10001/20001` with a hardcoded wallet, and the fee was
silently disabled only when the first configured pool host contained
`moneroocean.stream` — meaning everyone mining anywhere else paid it.

## What was removed here

| File | Change |
| --- | --- |
| `src/donate.h` | `kDefaultDonateLevel = 0`, `kMinimumDonateLevel = 0`; no address in the tree |
| `src/net/strategies/DonateStrategy.{h,cpp}` | deleted |
| `CMakeLists.txt` | donation sources removed from the target |
| `src/net/Network.{h,cpp}` | `m_donate` removed; no second strategy, no donation submit path, no tick |
| `src/core/Miner.{h,cpp}` | `setJob(job, donate)` → `setJob(job)`; job index always 0 |
| `src/base/net/stratum/Pools.{h,cpp}` | `donateLevel()` is a `constexpr` returning 0; the "disable fee if the pool matches" hack is gone |
| `src/base/kernel/config/BaseTransform.cpp` | `--donate-level` / `--donate-over-proxy` parsed and deliberately ignored |
| `src/core/config/Config_default.h` | `"donate-level": 0` |
| `src/Summary.cpp` | prints `DONATE 0% (fee-free build)` |

`--donate-level` and `--donate-over-proxy` are still **accepted** so existing
scripts, configs and dashboards keep working. Their values do nothing, and the
miner logs that it is ignoring them instead of silently honouring a number it
cannot pay.

## Why this is also a speed change

A donation round on RandomX is not 1 % of the time:

- the developer pool has a different seed → a full 2 GiB dataset
  re-initialisation;
- every worker thread is stopped and restarted → VMs and JIT code rebuilt, 2 MiB
  scratchpads faulted in again;
- the nonce window resets and in-flight hashes are lost;
- two extra pool sessions per round (connect, login, job).

Removing the fee therefore returns more than 1 % — typically 2–4 % of real
hashrate on RandomX, plus the full time slice.

## The published address is not a fee

The donation address in this project is documentation: a human may copy it, no
code path reads it. It appears in
[`doc/DONATE.md`](https://github.com/NggKhaiz/ZMRIG/blob/master/doc/DONATE.md)
and nowhere under `src/`, `zmrig/`, `pool/` or `oneclick.sh` — which is exactly
what the audit checks. Sending something is an invitation accepted or ignored,
never a charge.

## Licensing

XMRig is GPL-3.0. Deleting the donation code is a permitted modification of
source you received; copyright headers and the licence stay untouched. Upstream
is funded by that 1 % donation; this fork takes nothing and publishes one
optional address for people who insist.
