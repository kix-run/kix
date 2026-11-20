import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, test } from 'node:test';

import { SCHEMA, compareVersions, generate, parseSignature, parseSystems } from './release-index.mjs';

const SIGNATURE = `kix-release-signature v1\nkeyid=3f9a1c2e\nsignature=${Buffer.alloc(64, 7).toString('base64')}\n`;
const env = { SOURCE_DATE_EPOCH: '1762603200' };

function sums(version, systems) {
  const lines = systems.map((system, i) => `${String(i).repeat(64)}  kix-${system}.tar.gz`);
  lines.push(`${'a'.repeat(64)}  kix-${version}-third-party-sources.tar.zst`);
  lines.push(`${'b'.repeat(64)}  kix-${version}-x86_64-linux-cargo-audit.json`);
  return `${lines.join('\n')}\n`;
}

let src;
let out;

function release(version, { sig = SIGNATURE, systems = ['aarch64-darwin', 'x86_64-linux'], date } = {}) {
  const dir = join(src, `v${version}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'SHA256SUMS'), sums(version, systems));
  if (sig !== null) {
    writeFileSync(join(dir, 'SHA256SUMS.sig'), sig);
  }
  if (date) {
    writeFileSync(join(dir, 'date'), `${date}\n`);
  }
}

function run(withdrawn = []) {
  const warnings = [];
  const index = generate(src, out, { env, withdrawn, warn: (w) => warnings.push(w) });
  const written = JSON.parse(readFileSync(join(out, 'releases', 'index.json'), 'utf8'));
  assert.deepEqual(written, index);
  return { index, warnings };
}

beforeEach(() => {
  const root = mkdtempSync(join(tmpdir(), 'release-index-'));
  src = join(root, 'src');
  out = join(root, 'out');
  mkdirSync(src);
});

afterEach(() => {
  rmSync(join(src, '..'), { recursive: true, force: true });
});

test('writes the documented shape and copies the signed files', () => {
  release('0.8.4', { date: '2026-11-07', systems: ['x86_64-linux', 'aarch64-linux', 'aarch64-darwin'] });
  const { index, warnings } = run();
  assert.deepEqual(warnings, []);
  assert.deepEqual(index, {
    schema: SCHEMA,
    generated: '2025-11-08T12:00:00Z',
    expires: '2025-11-15T12:00:00Z',
    latest: '0.8.4',
    releases: [
      {
        version: '0.8.4',
        date: '2026-11-07',
        systems: ['aarch64-darwin', 'aarch64-linux', 'x86_64-linux'],
        sums: '/releases/v0.8.4/SHA256SUMS',
        signature: '/releases/v0.8.4/SHA256SUMS.sig',
        download: '/download/0.8.4/',
      },
    ],
    withdrawn: [],
  });
  assert.equal(readFileSync(join(out, 'releases/v0.8.4/SHA256SUMS.sig'), 'utf8'), SIGNATURE);
  assert.equal(
    readFileSync(join(out, 'releases/v0.8.4/SHA256SUMS'), 'utf8'),
    readFileSync(join(src, 'v0.8.4/SHA256SUMS'), 'utf8'),
  );
});

test('skips a release without a signature', () => {
  release('0.8.4');
  release('0.8.5', { sig: null });
  const { index, warnings } = run();
  assert.deepEqual(
    index.releases.map((r) => r.version),
    ['0.8.4'],
  );
  assert.equal(index.latest, '0.8.4');
  assert.match(warnings.join('\n'), /v0\.8\.5: it has no SHA256SUMS\.sig/);
});

test('skips a malformed signature', () => {
  const bad = [
    'kix-release-signature v2\nkeyid=3f9a1c2e\nsignature=AAAA\n',
    `kix-release-signature v1\nkeyid=3F9A\nsignature=${Buffer.alloc(64).toString('base64')}\n`,
    `kix-release-signature v1\nkeyid=3f9a1c2e\nsignature=${Buffer.alloc(32).toString('base64')}\n`,
    `kix-release-signature v1\nsignature=${Buffer.alloc(64).toString('base64')}\nkeyid=3f9a1c2e\n`,
    '',
  ];
  for (const sig of bad) {
    assert.equal(parseSignature(sig), null, JSON.stringify(sig));
  }
  release('0.8.4', { sig: bad[2] });
  const { index, warnings } = run();
  assert.deepEqual(index.releases, []);
  assert.match(warnings.join('\n'), /v0\.8\.4: SHA256SUMS\.sig is not a kix-release-signature v1 file/);
});

test('orders releases numerically, newest first', () => {
  for (const version of ['0.9.1', '0.10.0', '0.9.10', '0.2.0']) {
    release(version);
  }
  const { index } = run();
  assert.equal(index.latest, '0.10.0');
  assert.deepEqual(
    index.releases.map((r) => r.version),
    ['0.10.0', '0.9.10', '0.9.1', '0.2.0'],
  );
  assert.ok(compareVersions('0.10.0', '0.9.1') > 0);
});

test('lists prereleases after their release and never as latest', () => {
  for (const version of ['0.8.4', '0.9.0-rc.1', '0.9.0-rc.10', '0.9.0-rc.2']) {
    release(version);
  }
  let { index } = run();
  assert.equal(index.latest, '0.8.4');
  assert.deepEqual(
    index.releases.map((r) => [r.version, r.prerelease === true]),
    [
      ['0.9.0-rc.10', true],
      ['0.9.0-rc.2', true],
      ['0.9.0-rc.1', true],
      ['0.8.4', false],
    ],
  );
  assert.equal(index.releases[0].download, '/download/0.9.0-rc.10/');
  assert.equal(index.releases[0].sums, '/releases/v0.9.0-rc.10/SHA256SUMS');

  release('0.9.0');
  ({ index } = run());
  assert.equal(index.latest, '0.9.0');
  assert.equal(index.releases[0].version, '0.9.0');
  assert.ok(compareVersions('0.9.0', '0.9.0-rc.10') > 0);
  assert.ok(compareVersions('0.9.0-rc', '0.9.0-rc.1') < 0);
  assert.ok(compareVersions('0.9.0-beta', '0.9.0-rc.1') < 0);
  assert.ok(compareVersions('0.9.0-1', '0.9.0-rc') < 0);
});

test('writes an empty latest when only prereleases are signed', () => {
  release('0.9.0-rc.1');
  const { index } = run();
  assert.equal(index.latest, null);
  assert.equal(index.releases.length, 1);
});

test('reads the systems from the archive names in SHA256SUMS', () => {
  assert.deepEqual(parseSystems(sums('0.8.4', ['x86_64-linux', 'aarch64-darwin'])), ['aarch64-darwin', 'x86_64-linux']);
  assert.equal(parseSystems('not a sums line\n'), null);
  release('0.8.4', { systems: [] });
  const { index, warnings } = run();
  assert.deepEqual(index.releases, []);
  assert.match(warnings.join('\n'), /lists no kix-<system>\.tar\.gz/);
});

test('ignores directories that are not release tags', () => {
  release('0.8.4');
  mkdirSync(join(src, 'v0.9'));
  mkdirSync(join(src, 'latest'));
  const { index, warnings } = run();
  assert.deepEqual(
    index.releases.map((r) => r.version),
    ['0.8.4'],
  );
  assert.equal(warnings.length, 2);
});

test('writes the same output when run twice', () => {
  release('0.8.4', { date: '2026-11-07' });
  release('0.7.0');
  run();
  const first = readFileSync(join(out, 'releases', 'index.json'), 'utf8');
  run();
  assert.equal(readFileSync(join(out, 'releases', 'index.json'), 'utf8'), first);
});

test('writes an empty index when no release is signed', () => {
  release('0.7.0', { sig: null });
  const { index, warnings } = run();
  assert.deepEqual(index, {
    schema: SCHEMA,
    generated: '2025-11-08T12:00:00Z',
    expires: '2025-11-15T12:00:00Z',
    latest: null,
    releases: [],
    withdrawn: [],
  });
  assert.match(warnings.at(-1), /no release has a signed SHA256SUMS/);
});

test('writes an empty index when the source directory does not exist', () => {
  rmSync(src, { recursive: true });
  const { index } = run();
  assert.equal(index.latest, null);
  assert.deepEqual(index.releases, []);
});

test('moves a withdrawn release out of releases and never makes it latest', () => {
  release('0.8.3');
  release('0.8.4');
  const { index } = run([{ version: '0.8.4', reason: ' it deletes Secrets on rollback ', use: '0.8.3' }]);
  assert.deepEqual(
    index.releases.map((r) => r.version),
    ['0.8.3'],
  );
  assert.equal(index.latest, '0.8.3');
  assert.deepEqual(index.withdrawn, [
    { version: '0.8.4', reason: 'it deletes Secrets on rollback', use: '0.8.3' },
  ]);
  assert.equal(existsSync(join(out, 'releases/v0.8.4/SHA256SUMS')), false);
  assert.equal(existsSync(join(out, 'releases/v0.8.3/SHA256SUMS')), true);
});

test('stops on a withdrawal it cannot apply', () => {
  release('0.8.3');
  release('0.8.4');
  const entry = { version: '0.8.4', reason: 'it breaks', use: '0.8.3' };
  for (const [withdrawn, message] of [
    [{}, /must be a list/],
    [[{ ...entry, version: '0.8.9' }], /names no release/],
    [[{ ...entry, reason: '' }], /needs a reason/],
    [[{ ...entry, reason: 'say "no"' }], /needs a reason/],
    [[{ ...entry, reason: 'a {b}' }], /needs a reason/],
    [[{ ...entry, use: undefined }], /needs "use"/],
    [[{ ...entry, use: '0.8.9' }], /needs "use"/],
    [[entry, { version: '0.8.3', reason: 'it breaks too', use: '0.8.4' }], /needs "use"/],
  ]) {
    assert.throws(() => run(withdrawn), message, JSON.stringify(withdrawn));
  }
});
