// The donation address is published on the support page in both languages, and
// its QR code is copied into the site's static directory. One wrong character
// sends money nowhere, so the strings are compared against the wallet the pool
// actually pays out to — not against each other.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const SITE = path.resolve(import.meta.dirname, "..");
const ROOT = path.resolve(SITE, "..");

const { operatorAddress } = require(path.join(ROOT, "pool", "src", "operator.js"));

const ADDRESS = /\b4[1-9A-HJ-NP-Za-km-z]{94}\b/g;
const PAGES = [
  path.join(SITE, "docs", "support.md"),
  path.join(SITE, "i18n", "vi", "docusaurus-plugin-content-docs", "current", "support.md"),
];

test("the pool wallet is a plausible Monero address", () => {
  const address = operatorAddress();
  assert.match(address, /^4[1-9A-HJ-NP-Za-km-z]{94}$/);
  assert.equal(address.length, 95);
});

test("both support pages publish the wallet the pool pays to", () => {
  const expected = operatorAddress();
  for (const page of PAGES) {
    const text = fs.readFileSync(page, "utf8");
    const found = [...new Set(text.match(ADDRESS) || [])];
    assert.deepEqual(found, [expected], `${path.relative(ROOT, page)} carries a different address`);
  }
});

test("no wallet-shaped string appears anywhere else on the site", () => {
  const expected = operatorAddress();
  const files = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (["node_modules", "build", ".docusaurus"].includes(entry.name)) continue;
        walk(full);
      } else if (/\.(md|mdx|jsx?|mjs)$/.test(entry.name)) {
        files.push(full);
      }
    }
  };
  walk(SITE);

  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    for (const address of new Set(text.match(ADDRESS) || [])) {
      assert.equal(
        address,
        expected,
        `${path.relative(ROOT, file)} mentions a wallet that is not the operator's`
      );
    }
  }
});

test("the QR code served by the site is the documented one", () => {
  const served = path.join(SITE, "static", "img", "donate-monero.png");
  const documented = path.join(ROOT, "doc", "donate", "monero.png");
  assert.ok(fs.readFileSync(served).equals(fs.readFileSync(documented)));
});
