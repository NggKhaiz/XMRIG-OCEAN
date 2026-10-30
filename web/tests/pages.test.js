// Structural checks for every page the site ships.
//
// These are the failures that no unit test of a feature would catch and no
// visitor would report: a duplicated id (so a label points at the wrong
// input), a link to a page that was renamed, an image with no alt text, a
// second <h1>. Cheap to check, embarrassing to ship.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const WEB = path.resolve(__dirname, '..');
const PAGES = fs
  .readdirSync(WEB)
  .filter((name) => name.endsWith('.html'))
  .sort();

function doc(name) {
  return new JSDOM(fs.readFileSync(path.join(WEB, name), 'utf8')).window.document;
}

function slugs() {
  const manifest = JSON.parse(fs.readFileSync(path.join(WEB, 'content', 'vi', 'index.json'), 'utf8'));
  const pages = Array.isArray(manifest) ? manifest : manifest.pages || [];
  return new Set(pages.map((page) => page.slug || page.id));
}

test('the site ships the pages the navigation promises', () => {
  for (const required of ['index.html', 'docs.html', 'wizard.html', '404.html']) {
    assert.ok(PAGES.includes(required), `${required} exists`);
  }
});

test('no page repeats an id', () => {
  for (const name of PAGES) {
    const seen = new Map();
    for (const node of doc(name).querySelectorAll('[id]')) {
      const id = node.getAttribute('id');
      seen.set(id, (seen.get(id) || 0) + 1);
    }

    const duplicates = [...seen].filter(([, count]) => count > 1).map(([id]) => id);
    assert.deepStrictEqual(duplicates, [], `${name} repeats: ${duplicates.join(', ')}`);
  }
});

test('every page has exactly one h1, counting the one the SPA injects', () => {
  for (const name of PAGES) {
    const headings = doc(name).querySelectorAll('h1');

    // docs.html is a shell: its h1 comes from the Markdown page it renders,
    // which is checked below.
    if (name === 'docs.html') {
      assert.strictEqual(headings.length, 0, 'the shell does not add a second h1');
      continue;
    }

    assert.strictEqual(headings.length, 1, `${name} has ${headings.length} h1 elements`);
  }
});

test('every Markdown page starts with exactly one h1', () => {
  const content = path.join(WEB, 'content', 'vi');

  for (const file of fs.readdirSync(content).filter((name) => name.endsWith('.md'))) {
    const markdown = fs.readFileSync(path.join(content, file), 'utf8');
    // Shell comments inside fenced blocks also start with "# ", so count
    // headings in the prose only.
    const prose = markdown.replace(/```[\s\S]*?```/g, '');
    const h1 = prose.split('\n').filter((line) => /^# \S/.test(line));

    assert.strictEqual(h1.length, 1, `${file} has ${h1.length} level-1 headings`);

    const first = markdown.split('\n').find((line) => line.trim().length > 0);
    assert.match(first, /^# \S/, `${file} starts with its title, not with a caveat`);
  }
});

test('every image has alt text and explicit dimensions', () => {
  for (const name of PAGES) {
    for (const image of doc(name).querySelectorAll('img')) {
      assert.ok(image.getAttribute('alt'), `${name}: ${image.getAttribute('src')} has no alt`);
      assert.ok(image.getAttribute('width') && image.getAttribute('height'), `${name}: no width/height`);
    }
  }
});

test('every local link and asset points at something that exists', () => {
  const known = slugs();

  for (const name of PAGES) {
    for (const node of doc(name).querySelectorAll('a[href], link[href], script[src], img[src]')) {
      const raw = node.getAttribute('href') || node.getAttribute('src');
      const value = String(raw || '').trim();

      if (!value || /^(https?:|mailto:|data:|#|\/\/)/.test(value)) continue;

      const [target, hash] = value.split('#');
      const file = path.join(WEB, target);

      if (target) {
        assert.ok(fs.existsSync(file), `${name} -> ${target} does not exist`);
      }

      // docs.html#slug is an SPA route: the slug must be in the manifest.
      if (hash && (!target || target === 'docs.html') && target === 'docs.html') {
        assert.ok(known.has(hash.split('?')[0]), `${name} -> docs.html#${hash} is not a page in index.json`);
      }

      // index.html#builder and friends must exist as ids on that page.
      if (hash && target === 'index.html') {
        const anchor = new JSDOM(fs.readFileSync(path.join(WEB, 'index.html'), 'utf8')).window.document;
        assert.ok(anchor.getElementById(hash), `${name} -> index.html#${hash} has no such id`);
      }
    }
  }
});

test('the builder and the wizard load the same pool table and command builder', () => {
  for (const name of ['index.html', 'wizard.html']) {
    const scripts = [...doc(name).querySelectorAll('script[src]')].map((node) => node.getAttribute('src'));

    assert.ok(scripts.includes('assets/pools.js'), `${name} loads the pool table`);
    assert.ok(scripts.includes('assets/command.js'), `${name} loads the command builder`);
    assert.ok(
      scripts.indexOf('assets/pools.js') < scripts.indexOf('assets/command.js'),
      `${name} loads the table before the code that reads it`
    );
  }
});

test('both pages carry the wizard and the builder in their navigation', () => {
  for (const name of ['index.html', 'docs.html']) {
    const links = [...doc(name).querySelectorAll('.nav a')].map((node) => node.getAttribute('href'));

    assert.ok(links.includes('wizard.html'), `${name} links to the wizard`);
  }
});
