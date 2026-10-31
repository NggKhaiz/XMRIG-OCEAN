// The pool table is duplicated where it must be: `oneclick.sh` has to resolve a
// short name without Node, and `doc/POOLS.md` is read on GitHub. This test is
// what stops the three copies from drifting.
//
// It reads the other two sources as text. That is deliberate — a fee that is
// right in the site and stale in the installer is exactly the failure a
// hand-written table produces.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

import {
  POOLS,
  feeLabel,
  findPool,
  minLabel,
  presetEndpoint,
  presetNames,
} from "../src/lib/pools.mjs";

const ROOT = path.resolve(import.meta.dirname, "../..");
const ONE_CLICK = fs.readFileSync(path.join(ROOT, "oneclick.sh"), "utf8");
const POOLS_DOC = fs.readFileSync(path.join(ROOT, "doc", "POOLS.md"), "utf8");

test("every pool has a unique id and a valid host:port", () => {
  const ids = new Set();
  for (const pool of POOLS) {
    assert.ok(!ids.has(pool.id), `duplicate id ${pool.id}`);
    // The id is a URL parameter on the builder (?pool=c3pool), so it has to
    // survive a link: no spaces, no capitals, nothing that needs escaping.
    assert.match(pool.id, /^[a-z0-9-]+$/, `${pool.id} is not URL-safe`);
    ids.add(pool.id);
    assert.match(pool.host, /^[^\s:]+:\d{2,5}$/, pool.host);
    if (pool.tlsHost) assert.match(pool.tlsHost, /^[^\s:]+:\d{2,5}$/, pool.tlsHost);
    assert.ok(pool.fee >= 0 && pool.fee < 5, `${pool.id} fee`);
    assert.ok(pool.min > 0, `${pool.id} min`);
    assert.ok(pool.why.en && pool.why.vi, `${pool.id} needs both languages`);
  }
});

test("findPool accepts an id, a host:port and a tls:// URL", () => {
  assert.equal(findPool("moneroocean").id, "moneroocean");
  assert.equal(findPool("SupportXMR").id, "supportxmr");
  assert.equal(findPool("pool.supportxmr.com:3333").id, "supportxmr");
  assert.equal(findPool("tls://gulf.moneroocean.stream:443").id, "moneroocean");
  assert.equal(findPool("1.2.3.4:3333"), null);
  assert.equal(findPool(""), null);
});

test("the installer resolves the same endpoints as the site", () => {
  // `pool_preset` in oneclick.sh is a case statement of `name) echo "host:port"`,
  // and `resolve_pool` calls it for anything without a colon.
  const start = ONE_CLICK.indexOf("pool_preset()");
  assert.ok(start > 0, "oneclick.sh has no pool_preset()");
  const block = ONE_CLICK.slice(start, start + 1200);
  for (const pool of POOLS) {
    assert.ok(
      block.includes(pool.host),
      `oneclick.sh does not know ${pool.id} → ${pool.host}`
    );
  }
  // And the site must not invent a preset the installer cannot resolve.
  assert.deepEqual(
    [...presetNames()].sort(),
    POOLS.map((pool) => pool.id).sort()
  );
});

test("short aliases in the installer are covered by presetEndpoint", () => {
  assert.equal(presetEndpoint("moneroocean"), "gulf.moneroocean.stream:10001");
  assert.equal(presetEndpoint("supportxmr"), "pool.supportxmr.com:3333");
  assert.equal(presetEndpoint("p2pool-nano"), "pool.xmr.pub:3334");
  assert.equal(presetEndpoint("not-a-pool"), "");
});

test("doc/POOLS.md lists every endpoint and every short name", () => {
  for (const pool of POOLS) {
    // The P2Pool row abbreviates the second sidechain as `:3334`, so the port
    // is the part that has to be present, not the full host.
    const [host, port] = pool.host.split(":");
    assert.ok(POOLS_DOC.includes(host), `doc/POOLS.md is missing ${host}`);
    assert.ok(POOLS_DOC.includes(`:${port}`), `doc/POOLS.md is missing :${port}`);
  }
  for (const name of presetNames()) {
    assert.ok(POOLS_DOC.includes(`\`${name}\``), `doc/POOLS.md is missing ${name}`);
  }
});

test("the fee on each doc row matches the table", () => {
  for (const pool of POOLS) {
    const [host, port] = pool.host.split(":");
    const row = POOLS_DOC.split("\n").find(
      (line) => line.includes(host) && line.includes(`:${port}`)
    );
    assert.ok(row, `no row in doc/POOLS.md for ${pool.host}`);
    const fee = Number.isInteger(pool.fee) ? `${pool.fee} %` : `${pool.fee} %`;
    assert.ok(row.includes(fee), `${pool.id}: expected "${fee}" in "${row}"`);
  }
});

test("labels are honest about zero and non-zero fees, in both languages", () => {
  const ocean = findPool("moneroocean");
  const support = findPool("supportxmr");
  assert.equal(feeLabel(ocean, "en"), "0 %");
  assert.equal(feeLabel(support, "vi"), "0,6 %");
  assert.match(minLabel(ocean, "en"), /0\.003/);
  assert.match(minLabel(support, "vi"), /0,1/);
});

test("only MoneroOcean is marked as switching", () => {
  const switching = POOLS.filter((pool) => pool.switching).map((pool) => pool.id);
  assert.deepEqual(switching, ["moneroocean"]);
});
