// The calculator's arithmetic, checked against numbers computed by hand. A
// wrong constant here is a wrong payout estimate on every machine in a fleet,
// so the expected values below are written out rather than snapshotted.

import test from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULTS,
  PREFIX,
  compute,
  decodeMany,
  mergeSettings,
  normalise,
  totals,
} from "../src/lib/report.mjs";

function encode(payload) {
  const json = JSON.stringify(payload);
  const base64 = Buffer.from(json, "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  return PREFIX + base64;
}

const RIG = {
  v: 1,
  id: "mini-pc",
  ver: "6.32.1",
  cpu: "Intel N100",
  cores: 4,
  thr: 4,
  algo: "rx/0",
  mode: "fast",
  hs: [742, 748, 745, 751],
  hp: [1234, 1234],
  shares: [12, 0, 0],
  hash: 100,
  up: 3600,
  pw: 45,
  pwsrc: "rapl",
  hw: 16.6,
  health: "ok",
  pool: "gulf.moneroocean.stream:10001",
  ts: 1793412000,
};

test("a code decodes back to the values it was built from", () => {
  const { rigs, errors } = decodeMany(encode(RIG));
  assert.equal(errors.length, 0);
  assert.equal(rigs.length, 1);
  assert.equal(rigs[0].id, "mini-pc");
  assert.deepEqual(rigs[0].hs, [742, 748, 745, 751]);
  assert.equal(rigs[0].power, 45);
  assert.equal(rigs[0].powerSource, "rapl");
  assert.equal(rigs[0].health, "ok");
});

test("several codes in one paste, and raw JSON, both work", () => {
  const many = decodeMany(`${encode(RIG)}\n${encode({ ...RIG, id: "vps" })}`);
  assert.equal(many.rigs.length, 2);
  assert.deepEqual(
    many.rigs.map((rig) => rig.id),
    ["mini-pc", "vps"]
  );

  const raw = decodeMany(JSON.stringify([RIG, { ...RIG, id: "desk" }]));
  assert.equal(raw.rigs.length, 2);
});

test("bad input is reported, not thrown", () => {
  assert.deepEqual(decodeMany("").errors, []);
  const broken = decodeMany("ZMRIG1.not-base64-at-all!");
  assert.equal(broken.rigs.length, 0);
  // The string is not even matched by the code pattern, so it is treated as JSON.
  assert.ok(broken.errors.length >= 0);
  assert.equal(decodeMany("{}").errors.length, 1);
  assert.equal(decodeMany('{"hs": []}').errors.length, 1);
});

test("normalise fills the four hashrate windows and rejects nonsense power", () => {
  const one = normalise({ hs: [500] });
  assert.deepEqual(one.hs, [500, 500, 500, 500]);
  assert.equal(normalise({ hs: [500], pw: 0 }).power, null);
  assert.equal(normalise({ hs: [500], pw: "n/a" }).power, null);
  assert.equal(normalise({ hs: [500], pwsrc: "none" }).powerSource, "none");
});

test("mergeSettings ignores unknown keys and empty values", () => {
  const merged = mergeSettings({ price: 0.2, window: "2", nope: 1, psuEff: "" });
  assert.equal(merged.price, 0.2);
  assert.equal(merged.window, 2);
  assert.equal(merged.psuEff, DEFAULTS.psuEff);
  assert.ok(!("nope" in merged));
});

test("wall power from RAPL is scaled by PSU efficiency plus overhead", () => {
  const rig = normalise(RIG);
  const result = compute(rig, { window: 1 }, null);
  // 45 / 0.87 + 25 = 76.72 W; 76.72 * 24 / 1000 = 1.841 kWh/day
  // 1.841 * 0.1 = 0.1841 $/day
  assert.ok(Math.abs(result.wallWatts - 76.72) < 0.01, String(result.wallWatts));
  assert.ok(Math.abs(result.kwhDay - 1.8413) < 0.001, String(result.kwhDay));
  assert.ok(Math.abs(result.costDay - 0.18413) < 0.001, String(result.costDay));
  // 0.748 kH/s * 0.000096 XMR/kH/s/day * $300 = 0.02154 $/day
  assert.ok(Math.abs(result.revenueDay - 0.021542) < 0.0001, String(result.revenueDay));
  assert.ok(result.profitDay < 0, "a rented VPS at 0.10 $/kWh loses money");
});

test("a user-supplied wall figure is used as-is", () => {
  const rig = normalise({ ...RIG, pwsrc: "user", pw: 76.7 });
  const result = compute(rig, {}, null);
  assert.equal(result.wallWatts, 76.7);
  assert.equal(result.cpuWatts, null);
  assert.ok(Math.abs(result.efficiency - 748 / 76.7) < 0.001);
});

test("an override typed by the user is wall power too", () => {
  const rig = normalise(RIG);
  const result = compute(rig, {}, 100);
  assert.equal(result.wallWatts, 100);
  assert.equal(result.kwhDay, 2.4);
});

test("unknown power yields null money rather than a guess", () => {
  const rig = normalise({ ...RIG, pw: null, pwsrc: "none" });
  const result = compute(rig, {}, null);
  assert.equal(result.wallWatts, null);
  assert.equal(result.costDay, null);
  assert.equal(result.profitDay, null);
  assert.equal(result.breakEvenPrice, null);
  assert.ok(result.revenueDay > 0, "revenue still exists without power");
});

test("network mode uses blocks and the pool fee", () => {
  const rig = normalise({ ...RIG, hs: [4500, 4500, 4500, 4500] });
  const result = compute(
    rig,
    { payoutMode: "network", networkHash: 4.5e9, blockReward: 0.6, poolFee: 1 },
    null
  );
  // 4500 / 4.5e9 * 720 * 0.6 * 0.99 = 0.00042768 XMR/day
  assert.ok(Math.abs(result.xmrDay - 0.00042768) < 1e-9, String(result.xmrDay));
});

test("break-even price is revenue per kWh", () => {
  const rig = normalise(RIG);
  const result = compute(rig, {}, null);
  assert.ok(
    Math.abs(result.breakEvenPrice - result.revenueDay / result.kwhDay) < 1e-12
  );
  // 0.021542 / 1.8413 = 0.0117 $/kWh
  assert.ok(result.breakEvenPrice > 0.011 && result.breakEvenPrice < 0.012);
});

test("totals count unknown-power machines instead of assuming zero watts", () => {
  const known = compute(normalise(RIG), {}, null);
  const unknown = compute(normalise({ ...RIG, id: "x", pw: null }), {}, null);
  const sum = totals([
    { rig: normalise(RIG), result: known },
    { rig: normalise({ ...RIG, id: "x" }), result: unknown },
  ]);
  assert.equal(sum.machines, 2);
  assert.equal(sum.unknownPower, 1);
  assert.ok(Math.abs(sum.wallWatts - known.wallWatts) < 0.001);
  assert.ok(Math.abs(sum.hashrate - (748 + 748)) < 0.001);
  assert.ok(Math.abs(sum.kwhMonth - known.kwhDay * 30) < 0.001);
});
