import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';

const script = readFileSync(new URL('../public/install', import.meta.url), 'utf8');
const keysDir = new URL('../../cli/release-keys/', import.meta.url);

test('the install script carries the keys in cli/release-keys', () => {
  const match = script.match(/^RELEASE_KEYS='([^']*)'$/m);
  assert.ok(match, "web/public/install has no RELEASE_KEYS='...' line");
  const inScript = match[1].split(/\s+/).filter(Boolean).sort();

  const files = existsSync(keysDir) ? readdirSync(keysDir).filter((name) => name.endsWith('.pub')) : [];
  const inRepo = files
    .map((name) => {
      const hex = readFileSync(new URL(name, keysDir), 'utf8').trim();
      assert.match(hex, /^[0-9a-f]{64}$/, `${name} is not 64 lowercase hex digits`);
      const keyid = createHash('sha256').update(Buffer.from(hex, 'hex')).digest('hex').slice(0, 8);
      assert.equal(name, `${keyid}.pub`, `${name} should be named after its key id`);
      return hex;
    })
    .sort();

  assert.deepEqual(inScript, inRepo);
});

test('the install script runs nothing until its last line', () => {
  const lines = script.trimEnd().split('\n');
  assert.equal(lines.at(-1), 'main "$@"');
});
