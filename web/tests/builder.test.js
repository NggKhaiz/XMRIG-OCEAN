// The command builder is the part of the site that can hand somebody a wrong
// or dangerous command, so it is tested for real: the page is loaded in a DOM,
// the controls are driven like a visitor would, and the generated shell line is
// checked against what oneclick.sh actually accepts.
//
//   npm install --no-save jsdom
//   node --test web/tests/
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const ROOT = path.resolve(__dirname, '..', '..');
const PAGE = path.join(ROOT, 'web', 'index.html');

const VALID_WALLET = '4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge';

function load() {
  const html = fs.readFileSync(PAGE, 'utf8');
  const dom = new JSDOM(html, {
    runScripts: 'outside-only',
    url: 'https://example.test/',
    resources: undefined,
    pretendToBeVisual: true,
  });

  const { window } = dom;
  // The page loads its scripts with <script src>. jsdom does not fetch them, so
  // run them by hand in page order; that keeps the real files under test.
  const scripts = [...window.document.querySelectorAll('script[src]')].map((s) => s.getAttribute('src'));

  for (const src of scripts) {
    const file = path.join(ROOT, 'web', src.replace(/^\//, ''));
    const code = fs.readFileSync(file, 'utf8');
    const run = new window.Function(code);
    run.call(window);
  }

  window.document.dispatchEvent(new window.Event('DOMContentLoaded', { bubbles: true }));

  return window;
}

function setValue(window, id, value) {
  const el = window.document.getElementById(id);
  assert.ok(el, `#${id} exists`);
  el.value = value;
  el.dispatchEvent(new window.Event('input', { bubbles: true }));
  el.dispatchEvent(new window.Event('change', { bubbles: true }));
}

function command(window) {
  return window.document.getElementById('b-output').textContent;
}

test('a valid wallet produces a runnable one-liner', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);

  const text = command(window);

  assert.match(text, /curl -fsSL https:\/\/raw\.githubusercontent\.com\//);
  assert.match(text, /\| sudo bash -s -- install/);
  assert.ok(text.includes(VALID_WALLET), 'the wallet is in the command');
  assert.ok(text.includes('--yes'), 'never waits for a prompt');
  // The copy-paste block must end with the sudo command, as the design asks.
  assert.match(text.trim().split('\n').slice(-1)[0], /journalctl|status/);
});

test('an invalid wallet is refused instead of producing a command', () => {
  const window = load();
  setValue(window, 'b-wallet', 'not-a-wallet');

  const status = window.document.getElementById('b-status');
  assert.ok(status.textContent.length > 0, 'the page says what is wrong');
  assert.strictEqual(window.document.getElementById('b-copy').disabled, true);
});

test('the Cloudflare switch adds --cloudflare and a ws path, and forces zmrig', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);
  const cf = window.document.getElementById('b-cloudflare');
  cf.checked = true;
  cf.dispatchEvent(new window.Event('change', { bubbles: true }));

  const text = command(window);
  assert.ok(text.includes('--cloudflare'));
  assert.ok(text.includes('--ws-path'));
  assert.ok(text.includes('--engine zmrig'), 'the C++ engine cannot do WebSocket');
});

test('the MSR switch means --no-msr, because MSR is on by default', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);
  const msr = window.document.getElementById('b-msr');
  assert.ok(msr, '#b-msr exists');
  msr.checked = true;
  msr.dispatchEvent(new window.Event('change', { bubbles: true }));

  assert.ok(command(window).includes('--no-msr'));
});

test('a quote in a field cannot break out of the shell word', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);
  setValue(window, 'b-rig', "rig'; rm -rf / #");

  const text = command(window);
  assert.ok(text.includes("'rig'\\''; rm -rf / #'"), `unexpected quoting in: ${text}`);
  assert.ok(!/--rig-id rig'; rm/.test(text));
});

test('the dashboard maths still accepts the report the miner prints', () => {
  const window = load();

  // A code produced by `zmrig --report`, byte for byte.
  const code = process.env.ZMRIG_REPORT_CODE ||
    'ZMRIG1.eyJ2IjoxLCJpZCI6InptcmlnIiwidmVyIjoiNi4yNi4wLW1vOSIsImNwdSI6IkludGVsKFIpIFhlb24oUikgUHJvY2Vzc29yIEAgMi42MEdIeiIsImFyY2giOiJ4ODZfNjQiLCJjb3JlcyI6MSwidGhyIjoyLCJhbGdvIjoicngvMCIsIm1vZGUiOiJhdXRvIiwiaHMiOls3ODcuNyw3ODcuNyw3ODcuNyw3ODcuN10sImhwIjpbMCwwXSwic2hhcmVzIjpbMCwwLDBdLCJoYXNoIjoxOTY5NywidXAiOjAsInB3Ijo5NS4wLCJwd3NyYyI6InVzZXIiLCJwb29sIjoiYmVuY2htYXJrIiwidHMiOjE3OTMwMTE4Nzd9';

  const decoded = window.zmrigRig.decodeMany(code);
  assert.strictEqual(decoded.errors.length, 0, decoded.errors.join('; '));
  assert.strictEqual(decoded.rigs.length, 1);
  const rig = decoded.rigs[0];
  assert.strictEqual(rig.algo, 'rx/0');
  assert.strictEqual(rig.threads, 2);
  assert.strictEqual(Math.round(rig.hs[0]), 788);
  assert.strictEqual(rig.power, 95);
});

test('a corrupted report is rejected with a message, not a crash', () => {
  const window = load();
  const bad = window.zmrigRig.decodeMany('ZMRIG1.not-base64!!');
  assert.strictEqual(bad.rigs.length, 0);
  assert.ok(bad.errors.length > 0, 'the decoder explains what failed');

  const junk = window.zmrigRig.decodeMany('hello');
  assert.strictEqual(junk.rigs.length, 0);
  assert.ok(junk.errors.length > 0);
});

test('the default command carries no engine or profile flag', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);

  const text = command(window);

  // The zero-flag promise: absent means "detect it". A builder that always
  // pins an engine would quietly cancel the installer's own decision.
  assert.ok(!text.includes('--engine'), 'no --engine on the default path');
  assert.ok(!text.includes('--profile'), 'no --profile on the default path');
  assert.match(text, /\| sudo bash -s -- install/);
});

test('the profile selector adds --profile for free and watt only', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);
  setValue(window, 'b-profile', 'watt');
  assert.ok(command(window).includes('--profile watt'));

  setValue(window, 'b-profile', 'free');
  assert.ok(command(window).includes('--profile free'));

  setValue(window, 'b-profile', 'auto');
  assert.ok(!command(window).includes('--profile'), 'auto means no flag');
});

test('the C++ engine cannot be combined with the WebSocket switches', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);
  setValue(window, 'b-engine', 'xmrig');

  const cf = window.document.getElementById('b-cloudflare');
  cf.checked = true;
  cf.dispatchEvent(new window.Event('change', { bubbles: true }));

  const xmrig = window.document.querySelector('#b-engine option[value="xmrig"]');
  assert.strictEqual(xmrig.disabled, true, 'the option is disabled while it cannot work');
  assert.ok(command(window).includes('--engine zmrig'));
});
