import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';

const script = readFileSync(new URL('../public/install', import.meta.url), 'utf8');
// Return the hex keys in a key directory, checking each file's name.
function keysIn(dir) {
  const url = new URL(dir, import.meta.url);
  const files = existsSync(url) ? readdirSync(url).filter((name) => name.endsWith('.pub')) : [];
  return files
    .map((name) => {
      const hex = readFileSync(new URL(name, url), 'utf8').trim();
      assert.match(hex, /^[0-9a-f]{64}$/, `${name} is not 64 lowercase hex digits`);
      const keyid = createHash('sha256').update(Buffer.from(hex, 'hex')).digest('hex').slice(0, 8);
      assert.equal(name, `${keyid}.pub`, `${name} should be named after its key id`);
      return hex;
    })
    .sort();
}

// Return the hex keys the install script assigns to `name`.
function keysInScript(name) {
  const match = script.match(new RegExp(`^${name}='([^']*)'$`, 'm'));
  assert.ok(match, `web/public/install has no ${name}='...' line`);
  return match[1].split(/\s+/).filter(Boolean).sort();
}

test('the install script carries the keys in cli/kix/release-keys', () => {
  assert.deepEqual(keysInScript('RELEASE_KEYS'), keysIn('../../cli/kix/release-keys/'));
});

test('the install script carries the keys in cli/kix/index-keys', () => {
  const index = keysIn('../../cli/kix/index-keys/');
  assert.ok(index.length > 0, 'cli/kix/index-keys has no key');
  assert.deepEqual(keysInScript('INDEX_KEYS'), index);
  const release = new Set(keysIn('../../cli/kix/release-keys/'));
  assert.ok(index.every((key) => !release.has(key)), 'an index key is also a release key');
});

test('the install script runs nothing until its last line', () => {
  const lines = script.trimEnd().split('\n');
  assert.equal(lines.at(-1), 'main "$@"');
});
