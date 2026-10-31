// wizard.html is the page a first-time installer lands on, so it is driven the
// way a visitor drives it: type a wallet, click through the steps, pick a pool,
// read the command. The command itself is built by command.js — these tests
// check that the wizard hands it the right answers and never leaks the wallet
// into the URL or into a copied link.
//
//   npm install --no-save jsdom
//   node --test legacy/tests/
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const ROOT = path.resolve(__dirname, '..', '..');
const PAGE = path.join(ROOT, 'legacy', 'wizard.html');

const WALLET = '4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge';

function load(query = '') {
  const html = fs.readFileSync(PAGE, 'utf8');
  const dom = new JSDOM(html, {
    runScripts: 'outside-only',
    url: 'https://example.test/wizard.html' + query,
    pretendToBeVisual: true,
  });

  const { window } = dom;

  for (const script of [...window.document.querySelectorAll('script[src]')]) {
    const src = script.getAttribute('src');
    const code = fs.readFileSync(path.join(ROOT, 'legacy', src.replace(/^\//, '')), 'utf8');
    new window.Function(code).call(window);
  }

  window.document.dispatchEvent(new window.Event("DOMContentLoaded", { bubbles: true }));

  return window;
}

function visibleStep(window) {
  const panels = [...window.document.querySelectorAll('.w-step')];
  const shown = panels.filter((panel) => !panel.hidden);

  assert.strictEqual(shown.length, 1, 'exactly one step is visible');

  return Number(shown[0].getAttribute('data-panel'));
}

function click(window, id) {
  const node = window.document.getElementById(id);
  assert.ok(node, `#${id} exists`);
  node.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));
}

function type(window, id, value) {
  const node = window.document.getElementById(id);
  assert.ok(node, `#${id} exists`);
  node.value = value;
  node.dispatchEvent(new window.Event('input', { bubbles: true }));
  node.dispatchEvent(new window.Event('change', { bubbles: true }));
}

function choose(window, name, value) {
  const node = window.document.querySelector(`input[name="${name}"][value="${value}"]`);
  assert.ok(node, `radio ${name}=${value} exists`);
  node.checked = true;
  node.dispatchEvent(new window.Event('change', { bubbles: true }));
}

test('the wizard opens on step 1 and refuses to advance without a wallet', () => {
  const window = load();

  assert.strictEqual(visibleStep(window), 1);

  click(window, 'w-next');

  assert.strictEqual(visibleStep(window), 1, 'still on the wallet step');
  assert.ok(window.document.getElementById('w-blocked').textContent.length > 0, 'says why');

  type(window, 'w-wallet', 'not-a-wallet');
  click(window, 'w-next');
  assert.strictEqual(visibleStep(window), 1, 'a broken wallet is refused too');
});

test('a valid wallet opens every later step, and the steps stay in order', () => {
  const window = load();
  type(window, 'w-wallet', WALLET);

  for (const expected of [2, 3, 4, 5]) {
    click(window, 'w-next');
    assert.strictEqual(visibleStep(window), expected);
  }

  // The last step hides "next" and shows the command.
  assert.strictEqual(window.document.getElementById('w-next').hidden, true);
  assert.ok(window.document.getElementById('w-output').textContent.includes(WALLET));

  click(window, 'w-back');
  assert.strictEqual(visibleStep(window), 4);
});

test('the pool step offers every pool in the table, plus a custom one', () => {
  const window = load('?step=2');
  const cards = [...window.document.querySelectorAll('.pool-card[data-pool]')];

  assert.strictEqual(cards.length, window.zmrigPools.list.length + 1);
  for (const pool of window.zmrigPools.list) {
    assert.ok(
      cards.some((card) => card.getAttribute('data-pool') === pool.id),
      `${pool.id} has a card`
    );
  }
});

test('picking a pool changes the endpoint the wizard prints', () => {
  const window = load('?step=2');
  type(window, 'w-wallet', WALLET);

  choose(window, 'w-pool', 'c3pool');
  click(window, 'w-next');
  click(window, 'w-next');
  click(window, 'w-next');

  const text = window.document.getElementById('w-output').textContent;
  assert.ok(text.includes('--pool c3pool.com:3333'), text);
  assert.ok(!text.includes('gulf.moneroocean.stream'), 'the old pool is gone');
});

test('TLS on a pool with a published 443 port becomes tls://host:443', () => {
  const window = load('?step=2');
  type(window, 'w-wallet', WALLET);

  choose(window, 'w-pool', 'supportxmr');
  const tls = window.document.getElementById('w-tls');
  tls.checked = true;
  tls.dispatchEvent(new window.Event('change', { bubbles: true }));

  click(window, 'w-next');
  click(window, 'w-next');
  click(window, 'w-next');

  assert.ok(window.document.getElementById('w-output').textContent.includes('tls://pool.supportxmr.com:443'));
});

test('a pool without a TLS port unticks TLS instead of emitting a port that will be refused', () => {
  const window = load('?step=2');

  choose(window, 'w-pool', 'c3pool');
  const tls = window.document.getElementById('w-tls');
  tls.checked = true;
  tls.dispatchEvent(new window.Event('change', { bubbles: true }));

  assert.strictEqual(tls.checked, false);
  assert.match(window.document.getElementById('w-tls-hint').textContent, /không công bố/i);
});

test('a backup pool appears as --failover, and a pool cannot back itself up', () => {
  const window = load('?step=2');
  type(window, 'w-wallet', WALLET);

  choose(window, 'w-pool', 'moneroocean');
  const failover = window.document.getElementById('w-failover');

  const own = [...failover.options].find((option) => option.value === 'moneroocean');
  assert.strictEqual(own.disabled, true, 'the primary pool is not offered as its own backup');

  failover.value = 'c3pool';
  failover.dispatchEvent(new window.Event('change', { bubbles: true }));

  click(window, 'w-next');
  click(window, 'w-next');
  click(window, 'w-next');

  assert.ok(window.document.getElementById('w-output').textContent.includes('--failover c3pool.com:3333'));
});

test('the wallet never reaches the URL, so a shared link cannot carry it', () => {
  const window = load();
  type(window, 'w-wallet', WALLET);
  click(window, 'w-next');

  assert.ok(!window.location.search.includes(WALLET));
  assert.ok(!window.location.search.includes(WALLET.slice(0, 12)));
  assert.ok(window.location.search.includes('step=2'));
});

test('a deep link restores the choices a shared link carries', () => {
  const window = load('?step=5&pool=supportxmr&engine=zmrig&tls=1');
  type(window, 'w-wallet', WALLET);
  click(window, 'w-back');
  click(window, 'w-next');

  const text = window.document.getElementById('w-output').textContent;
  assert.ok(text.includes('--pool tls://pool.supportxmr.com:443'), text);
  assert.ok(text.includes('--engine zmrig'));
});

test('the wizard and the quick builder produce the same command for the same answers', () => {
  const window = load('?step=5&pool=moneroocean');
  type(window, 'w-wallet', WALLET);

  const fromBuilder = window.zmrigCommand.build({ wallet: WALLET, pool: 'moneroocean' }).install;
  const fromWizard = window.document.getElementById('w-output').textContent;

  assert.strictEqual(fromWizard, fromBuilder);
});

test('the custom pool needs a host, and says so before it hands over a command', () => {
  const window = load('?step=2');
  type(window, 'w-wallet', WALLET);

  choose(window, 'w-pool', 'custom');
  assert.strictEqual(window.document.getElementById('w-host-field').hidden, false);

  click(window, 'w-next');
  assert.strictEqual(visibleStep(window), 2, 'blocked on the missing host');

  type(window, 'w-host', 'pool.internal.example:3333');
  click(window, 'w-next');
  click(window, 'w-next');
  click(window, 'w-next');

  assert.ok(window.document.getElementById('w-output').textContent.includes('--pool pool.internal.example:3333'));
});
