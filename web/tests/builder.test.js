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

  // One command, one line of intent: `curl … | sudo bash`. The follow-up
  // commands (status, journalctl, report) live in their own copy button, so
  // pasting this block cannot start a second thing by accident.
  const lines = text.trim().split('\n');
  assert.strictEqual(lines.length, 2, `expected the two-line pipeline, got: ${text}`);
  assert.match(lines[0], /^curl -fsSL /);
  assert.match(lines[1], /^  \| sudo bash -s -- install /);
  assert.ok(!/^sudo /m.test(text), 'sudo appears only inside the pipeline');
  assert.ok(text.trim().endsWith('--yes'), 'the command ends with --yes');
});

test('the follow-up commands are available separately and never include the wallet', () => {
  const window = load();
  const after = window.zmrigCommand.build({ wallet: VALID_WALLET }).commands.after;

  assert.match(after, /systemctl status xmrig-ocean/);
  assert.match(after, /journalctl/);
  assert.ok(!after.includes(VALID_WALLET), 'no wallet in the log commands');
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

test('the pool list comes from the shared table, not from markup that can rot', () => {
  const window = load();
  const select = window.document.getElementById('b-pool');
  const values = [...select.options].map((option) => option.value);

  for (const pool of window.zmrigPools.list) {
    assert.ok(values.includes(pool.id), `${pool.id} is offered`);
  }
  assert.ok(values.includes('custom'), 'a custom pool is offered');
  assert.ok(select.selectedOptions[0].textContent.includes('gulf.moneroocean.stream:10001'), 'the default shows its endpoint');
});

test('choosing a pool changes the endpoint, the fee and the explanation', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);
  setValue(window, 'b-pool', 'supportxmr');

  const text = command(window);
  assert.ok(text.includes('--pool pool.supportxmr.com:3333'), text);
  assert.ok(!text.includes('gulf.moneroocean.stream'), 'the previous pool is gone');

  const info = window.document.getElementById('b-pool-info').textContent;
  assert.match(info, /0,6 %/);
  assert.match(info, /0,1 XMR/);
  assert.strictEqual(window.document.getElementById('b-pool-tag').textContent, 'SupportXMR · 0,6 %');
});

test('the TLS switch uses the published 443 endpoint of the chosen pool', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);
  setValue(window, 'b-pool', 'moneroocean');

  const tls = window.document.getElementById('b-tls');
  tls.checked = true;
  tls.dispatchEvent(new window.Event('change', { bubbles: true }));

  assert.ok(command(window).includes('--pool tls://gulf.moneroocean.stream:443'), command(window));
});

test('a backup pool becomes --failover, and the primary cannot be its own backup', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);
  setValue(window, 'b-pool', 'moneroocean');

  const boxes = [...window.document.querySelectorAll('#b-failover input[data-failover]')];
  assert.strictEqual(boxes.length, window.zmrigPools.list.length);

  const c3 = boxes.find((box) => box.getAttribute('data-failover') === 'c3pool');
  const self = boxes.find((box) => box.getAttribute('data-failover') === 'moneroocean');
  c3.checked = true;
  self.checked = true;
  c3.dispatchEvent(new window.Event('change', { bubbles: true }));

  const text = command(window);
  assert.ok(text.includes('--failover c3pool.com:3333'), text);
  assert.ok(!text.includes('gulf.moneroocean.stream:10001,c3pool'), 'the primary is not repeated');
});

test('the preview command is a plan: it changes nothing on the host', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);

  const result = window.zmrigCommand.build({ wallet: VALID_WALLET, pool: 'c3pool', failover: ['moneroocean'] });

  assert.match(result.plan, /\| sudo bash -s -- plan /);
  assert.ok(!result.plan.includes(' install '), 'no install in the preview');
  assert.ok(result.plan.includes('--failover gulf.moneroocean.stream:10001'));
});

test('a custom pool must be host:port before the copy button unlocks', () => {
  const window = load();
  setValue(window, 'b-wallet', VALID_WALLET);
  setValue(window, 'b-pool', 'custom');
  setValue(window, 'b-host', 'nonsense');

  assert.strictEqual(window.document.getElementById('b-copy').disabled, true);
  assert.match(window.document.getElementById('b-host-hint').textContent, /host:port/i);

  setValue(window, 'b-host', 'pool.internal.example:3333');
  assert.strictEqual(window.document.getElementById('b-copy').disabled, false);
  assert.ok(command(window).includes('--pool pool.internal.example:3333'));
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

test('the report decoder understands health and hashes per watt, and tolerates their absence', () => {
  const window = load();
  const rig = window.zmrigRig;
  assert.ok(rig && typeof rig.normalise === 'function', 'the decoder is exposed');

  // decodeMany takes the paste buffer and returns {rigs, errors}.
  const one = (json) =>
    window.btoa(JSON.stringify(json)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const withHealth = rig.decodeMany(
    'ZMRIG1.' +
      one({
        v: 1, id: 'rig-1', hs: [1000, 990, 980, 1010], thr: 4, cores: 2,
        pw: 100, pwsrc: 'hwmon', hw: 9.9, health: 'degraded', pool: 'p:1',
      })
  ).rigs[0];

  assert.strictEqual(withHealth.health, 'degraded');
  assert.strictEqual(withHealth.hashesPerWatt, 9.9);

  const without = rig.decodeMany('ZMRIG1.' + one({ v: 1, id: 'rig-2', hs: [500] })).rigs[0];

  // An old code must decode to an empty health, not to "stalled".
  assert.strictEqual(without.health, '');
  assert.strictEqual(without.hashesPerWatt, null);
});
