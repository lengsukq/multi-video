import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';

/** Regression guard for all intentional public HTTP endpoints. */
test('typed router inventory contains only provider-neutral room and recording APIs', () => {
  const expected = JSON.parse(
    readFileSync(new URL('./route-inventory.expected.json', import.meta.url), 'utf8'),
  ) as [string, string][];
  const base = new URL('../', import.meta.url);
  const routeFiles = readdirSync(new URL('routes/', base))
    .filter((name) => name.endsWith('.ts'))
    .map((name) => `routes/${name}`);
  const files = ['app.ts', ...routeFiles];
  const actual = new Set<string>();

  for (const file of files) {
    const text = readFileSync(new URL(file, base), 'utf8');
    const endpoints = text.matchAll(
      /app\.(get|post|put|patch|delete)\s*\(\s*['"`](.*?)['"`]/g,
    );
    for (const match of endpoints) {
      actual.add(JSON.stringify([match[1]!.toUpperCase(), match[2]]));
    }
  }
  const sorted = [...actual].map((item) => JSON.parse(item) as [string, string])
    .sort(([verbA, pathA], [verbB, pathB]) =>
      verbA.localeCompare(verbB) || pathA.localeCompare(pathB));
  const baseline = [...expected].sort(([verbA, pathA], [verbB, pathB]) =>
    verbA.localeCompare(verbB) || pathA.localeCompare(pathB));
  assert.deepEqual(sorted, baseline);
  assert.equal(sorted.length, 50);
});
