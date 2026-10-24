const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../tongye-flash-introduction.html'), 'utf8');
const urls = ['build/同页-0.7.2-arm64.dmg', 'build/同页-0.7.2-x86_64.dmg'];

test('both architectures have current download links', () => {
  const links = [...html.matchAll(/<a\b[^>]*href="([^"]+)"[^>]*>/g)];
  for (const url of urls) assert.equal(links.filter(link => link[1] === url).length, 1);
  assert.doesNotMatch(html, /万历十五年/);
  assert.match(html, /不附带内置阅读资料/);
  assert.match(html, /Intel/);
  assert.match(html, /id="download"/);
  assert.match(html, /href="#download"/);
  assert.match(html, /下载 Mac 版/);
});

test('installer requirements and safe installation guidance are visible', () => {
  assert.match(html, /macOS 14/);
  assert.match(html, /Apple Silicon/);
  assert.match(html, /Applications/);
  assert.match(html, /尚未公证/);
});

test('all five original feature tabs and their panel remain available', () => {
  assert.equal((html.match(/role="tab"/g) || []).length, 5);
  assert.match(html, /id="stage" role="tabpanel"/);
  assert.match(html, /prefers-reduced-motion/);
});
