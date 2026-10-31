// The donation address is published in four places (README, doc/DONATE.md, the
// landing page and the Vietnamese guide). A single character wrong in any of
// them sends somebody's money into the void, so the strings are compared with
// the wallet the pool actually pays out to instead of with each other.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const { operatorAddress } = require(path.join(ROOT, 'pool', 'src', 'operator.js'));

// A Monero mainnet address is 95 base58 characters and starts with 4.
const ADDRESS = /\b4[1-9A-HJ-NP-Za-km-z]{94}\b/g;

const PLACES = [
  'README.md',
  'doc/DONATE.md',
  'legacy/index.html',
  'legacy/content/vi/gioi-thieu.md',
];

test('the pool wallet is a plausible Monero address', () => {
  const address = operatorAddress();

  assert.match(address, /^4[1-9A-HJ-NP-Za-km-z]{94}$/);
  assert.strictEqual(address.length, 95);
});

test('every published address is the wallet the pool pays to', () => {
  const expected = operatorAddress();

  for (const file of PLACES) {
    const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
    const found = text.match(ADDRESS) || [];

    assert.ok(found.length > 0, `${file} publishes the address`);
    for (const address of found) {
      assert.strictEqual(address, expected, `${file} carries a different address`);
    }
  }
});

test('no other wallet-shaped string is published as a donation address', () => {
  // Anything that looks like an address but is not the operator wallet is a
  // typo, a stale copy or an impostor: fail loudly rather than ship it.
  const expected = operatorAddress();

  for (const file of PLACES) {
    const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
    const unique = new Set(text.match(ADDRESS) || []);
    unique.delete(expected);

    assert.deepStrictEqual([...unique], [], `${file} mentions an unknown address`);
  }
});

test('the QR code shipped to the site is byte-identical to the documented one', () => {
  const doc = fs.readFileSync(path.join(ROOT, 'doc', 'donate', 'monero.png'));
  const site = fs.readFileSync(path.join(ROOT, 'legacy', 'assets', 'donate-monero.png'));

  assert.ok(doc.length > 200, 'the QR is a real image');
  assert.ok(doc.equals(site), 'the two copies match');
});
