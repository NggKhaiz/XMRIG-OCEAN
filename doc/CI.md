# CI

The repository ships `.github/workflows/test.yml` for Linux and macOS. The Linux
job builds the miner and runs the safe hash suite.

Two extra checks are worth adding; they are not in the workflow file because a
token needs the `workflows` scope to modify those files. Paste them into the
Linux job after `Run safe test subset`:

```yaml
      - name: Verify zero developer fee
        run: ./scripts/verify-fee-free.sh --binary build/xmrig

      - name: Run miner integration tests
        run: node run_tests.js --suite miner-integration --build-dir build
```

What they cover:

| Check | What it proves |
|---|---|
| `verify-fee-free.sh` | no donation strategy in the source or the binary, no developer wallet, `DONATE 0%` even when `--donate-level=9` is passed |
| `miner-integration` | the built binary talks stratum, accepts a job and submits a share for all 34 CPU algorithms (`tests/common/miner_harness.js` runs a fake pool) |

For `zmrig`, the equivalent is the network suite (no CI privileges needed, it
starts its own pools and TLS shims):

```yaml
      - name: zmrig self test
        run: ./zmrig/out/zmrig --self-test

      - name: zmrig network suite
        run: ./zmrig/tests/net.sh --quick
```

Both run locally as well:

```bash
./scripts/verify-fee-free.sh --binary build/xmrig
node run_tests.js --suite miner-integration --build-dir build
node run_tests.js --safe --build-dir build
```
