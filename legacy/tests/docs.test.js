// The documentation site renders Markdown in the browser. These tests feed the
// real renderer the real content files and check the result: every page in the
// manifest exists, headings get the ids the table of contents links to, and
// code blocks are rendered (not swallowed as paragraphs).
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const ROOT = path.resolve(__dirname, '..', '..');
const CONTENT = path.join(ROOT, 'legacy', 'content', 'vi');

function window() {
  const dom = new JSDOM('<!doctype html><html><body><article id="doc"></article></body></html>', {
    runScripts: 'outside-only',
    url: 'https://example.test/docs.html',
  });
  const { window: w } = dom;

  for (const file of ['site.js', 'md.js']) {
    const code = fs.readFileSync(path.join(ROOT, 'legacy', 'assets', file), 'utf8');
    new w.Function(code).call(w);
  }

  return w;
}

test('every page in the manifest exists and renders', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(CONTENT, 'index.json'), 'utf8'));
  const pages = Array.isArray(manifest) ? manifest : manifest.pages || manifest.items || [];

  assert.ok(pages.length >= 5, `expected several pages, got ${pages.length}`);

  for (const page of pages) {
    const slug = page.slug || page.id || page.file;
    const file = path.join(CONTENT, `${slug}.md`);
    assert.ok(fs.existsSync(file), `${slug}.md exists`);

    const markdown = fs.readFileSync(file, 'utf8');
    const rendered = window().zmrigMarkdown.render(markdown);
    const html = rendered.html;

    assert.ok(html.length > 200, `${slug} renders something`);
    assert.ok(/<h[12]/.test(html), `${slug} has a heading`);
    if (markdown.includes('```')) {
      assert.ok(html.includes('<pre'), `${slug} renders its code blocks`);
    }
  }
});

test('headings get ids that the table of contents can link to', () => {
  const w = window();
  const markdown = fs.readFileSync(path.join(CONTENT, 'cai-dat.md'), 'utf8');
  const html = w.zmrigMarkdown.render(markdown).html;

  const doc = new JSDOM(`<body>${html}</body>`).window.document;
  const headings = [...doc.querySelectorAll('h2, h3')];

  assert.ok(headings.length > 0);
  for (const heading of headings) {
    assert.ok(heading.id, `heading "${heading.textContent}" has an id`);
    assert.match(heading.id, /^[a-z0-9-]+$/);
  }
});

test('html in the markdown source is escaped, not executed', () => {
  const w = window();
  const html = w.zmrigMarkdown.render('text <img src=x onerror="alert(1)"> more').html;

  assert.ok(!html.includes('<img'), 'raw html does not survive');
  assert.ok(html.includes('&lt;img'));
});

test('images render, and only from a place a page can load', () => {
  const w = window();

  const local = w.zmrigMarkdown.render('![QR](assets/donate-monero.png)').html;
  assert.ok(local.includes('<img src="assets/donate-monero.png"'), 'a relative asset renders');
  assert.ok(local.includes('alt="QR"'), 'the alt text is kept');

  // A quote or a script in either half must not escape the attribute or the tag.
  const hostile = w.zmrigMarkdown.render('![x"><script>alert(1)</script>](javascript:alert(1))').html;
  assert.ok(!hostile.includes('<script'), 'no script tag survives');
  assert.ok(!hostile.includes('<img src="javascript:'), 'a javascript: src is not used');
});

test('a javascript: link is dead text, not a link', () => {
  const w = window();
  const html = w.zmrigMarkdown.render('[click me](javascript:alert(1))').html;

  assert.ok(!html.includes('<a '), 'no anchor is produced');
  assert.ok(html.includes('click me'), 'the label is still readable');

  const https = w.zmrigMarkdown.render('[site](https://example.test/x)').html;
  assert.ok(https.includes('href="https://example.test/x"'));
  assert.ok(https.includes('rel="noreferrer"'), 'external links open safely');
});

test('a link whose label is a code span still renders as a link', () => {
  const w = window();
  const html = w.zmrigMarkdown.render('See [`doc/DONATE.md`](https://example.test/d.md) for details.').html;
  const doc = new JSDOM(`<body>${html}</body>`).window.document;
  const link = doc.querySelector('a');

  assert.ok(link, 'the anchor survives the code span inside its label');
  assert.strictEqual(link.getAttribute('href'), 'https://example.test/d.md');
  assert.strictEqual(link.querySelector('code').textContent, 'doc/DONATE.md');
  assert.ok(!html.includes('\u0000'), 'no placeholder leaks into the output');
});
