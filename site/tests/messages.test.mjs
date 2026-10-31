// The two message tables are the entire UI of the builder, the calculator and
// the pool table. A key that exists in one language only renders as its own key
// (`calc.payout`) in the other, which is the kind of thing nobody notices until
// a user reports a page full of dots.
//
// The components also build keys at runtime — `t("builder.wallet." + status)` —
// so the prefixes are listed here explicitly instead of being inferred.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

import { messages, translate } from "../src/lib/messages.mjs";

const SITE = path.resolve(import.meta.dirname, "..");
const en = messages.en;
const vi = messages.vi;

const enKeys = Object.keys(en).sort();
const viKeys = Object.keys(vi).sort();

function componentSource() {
  const dir = path.join(SITE, "src", "components");
  return fs
    .readdirSync(dir)
    .filter((name) => name.endsWith(".jsx"))
    .map((name) => fs.readFileSync(path.join(dir, name), "utf8"))
    .join("\n");
}

test("English and Vietnamese define exactly the same keys", () => {
  assert.deepEqual(viKeys, enKeys);
  assert.ok(enKeys.length > 100, `only ${enKeys.length} keys`);
});

test("no message is empty, and no Vietnamese message is still English", () => {
  for (const key of enKeys) {
    assert.ok(en[key].trim().length > 0, `${key} is empty in English`);
    assert.ok(vi[key].trim().length > 0, `${key} is empty in Vietnamese`);
  }
  // These are the only strings where the two languages genuinely agree: they
  // are either a proper noun or a word that Vietnamese uses unchanged.
  const allowed = new Set([
    "builder.pool",
    "builder.engine",
    "calc.hashrate",
    "pooltable.pool",
    "pooltable.endpoint",
  ]);
  const identical = enKeys.filter((key) => en[key] === vi[key]);
  assert.deepEqual(
    identical.filter((key) => !allowed.has(key)),
    [],
  );
});

test("every key a component asks for literally exists", () => {
  const used = new Set(
    [...componentSource().matchAll(/\bt\("([a-z0-9.]+)"/g)]
      .map((match) => match[1])
      // `t("builder.wallet." + status)` is a prefix, not a key.
      .filter((key) => !key.endsWith(".")),
  );
  assert.ok(used.size > 40, `only ${used.size} literal keys found`);
  for (const key of used)
    assert.ok(key in en, `component asks for unknown key ${key}`);
});

test("the keys built from a status at runtime all exist", () => {
  const groups = {
    "builder.wallet.": ["empty", "charset", "length", "valid", "integrated"],
    "builder.host.": ["empty", "shape", "port", "ok"],
    "builder.note.": [
      "notune",
      "tls443",
      "autotuneOff",
      "noHealthRestart",
      "profileWatt",
      "profileFree",
    ],
    "builder.warn.": ["engineForced", "noTlsPort", "switchingPool"],
    "builder.blocked.": [
      "wallet-empty",
      "wallet-invalid",
      "host-invalid",
      "proxy-missing",
      "proxy-invalid",
      "connect-to-invalid",
    ],
  };
  for (const [prefix, suffixes] of Object.entries(groups)) {
    for (const suffix of suffixes) {
      const key = prefix + suffix;
      assert.ok(key in en, `missing ${key} (English)`);
      assert.ok(key in vi, `missing ${key} (Vietnamese)`);
    }
  }
});

test("the source file declares no key twice per locale", () => {
  // A duplicated key is not an error in JavaScript: the last one quietly wins,
  // which is how the Vietnamese text of a new entry ended up inside the English
  // table while this file was being edited.
  const source = fs.readFileSync(
    path.join(SITE, "src", "lib", "messages.mjs"),
    "utf8",
  );
  const en = source.slice(
    source.indexOf("\n  en: {"),
    source.indexOf("\n  vi: {"),
  );
  const vi = source.slice(source.indexOf("\n  vi: {"));
  const keys = (block) =>
    [...block.matchAll(/^ {4}"([A-Za-z0-9.-]+)":/gm)].map((m) => m[1]);

  for (const [locale, block] of [
    ["en", en],
    ["vi", vi],
  ]) {
    const seen = new Set();
    const repeated = [];
    for (const key of keys(block)) {
      if (seen.has(key)) repeated.push(key);
      seen.add(key);
    }
    assert.deepEqual(repeated, [], `${locale} declares these keys twice`);
  }
});

test("translate fills placeholders and falls back predictably", () => {
  assert.equal(translate("en", "no.such.key"), "no.such.key");
  assert.equal(translate("vi", "builder.copy"), vi["builder.copy"]);
  // A placeholder that is not supplied stays visible rather than becoming
  // "undefined" in the middle of a sentence.
  const template = "x {name} y";
  const filled = translate("en", "pooltable.checked");
  assert.equal(typeof filled, "string");
  assert.ok(!filled.includes("undefined"));
  assert.ok(template);
});

test("the locale strings only contain valid placeholders", () => {
  for (const key of enKeys) {
    for (const [, name] of en[key].matchAll(/\{(\w+)\}/g)) {
      assert.ok(
        vi[key].includes(`{${name}}`),
        `${key} uses {${name}} in English but not in Vietnamese`,
      );
    }
  }
});
