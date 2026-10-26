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
const CONTENT = path.join(ROOT, 'web', 'content', 'vi');

function window() {
  const dom = new JSDOM('<!doctype html><html><body><article id="doc"></article></body></html>', {
    runScripts: 'outside-only',
    url: 'https://example.test/docs.html',
  });
  const { window: w } = dom;

  for (const file of ['site.js', 'md.js']) {
    const code = fs.readFileSync(path.join(ROOT, 'web', 'assets', file), 'utf8');
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
