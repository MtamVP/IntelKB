import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

test('standalone preview preserves JavaScript and contains exactly one valid module', () => {
  const build = spawnSync(process.execPath, [fileURLToPath(new URL('../build-preview.mjs', import.meta.url))], {encoding:'utf8'});
  assert.equal(build.status, 0, build.stderr);
  const html = fs.readFileSync(new URL('../preview.html', import.meta.url), 'utf8');
  const scripts = [...html.matchAll(/<script type="module">([\s\S]*?)<\/script>/g)];
  assert.equal(scripts.length, 1);
  assert.equal((html.match(/<\/body>/g) || []).length, 1);
  assert.ok(html.trimEnd().endsWith('</html>'));
  assert.ok(scripts[0][1].includes("')$', 'iu')"));
  const parse = spawnSync(process.execPath, ['--check', '--input-type=module'], {input: scripts[0][1], encoding:'utf8'});
  assert.equal(parse.status, 0, parse.stderr);
  assert.ok(!scripts[0][1].includes("fetch('./words.json')"));
  assert.ok(!/^import /m.test(scripts[0][1]));
  assert.ok(!html.includes('workbench-ink-7c91'));
  assert.ok(!html.includes('auth-password'));
});
