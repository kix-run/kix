#!/usr/bin/env node
// Write kix.run/releases/index.json, the list of Kix releases that Kix and
// the install script read.
//
//   node release-index.mjs <src-dir> <out-dir> [<withdrawn.json>]
//
// <src-dir> holds one directory per release tag, `v<version>/`, with that
// release's SHA256SUMS and SHA256SUMS.sig and an optional `date` file
// (YYYY-MM-DD). pages.yml fetches them from the release host. A release
// without both files, or with a signature file that does not parse, is left
// out. The script writes <out-dir>/releases/index.json and copies each listed
// release's two files to <out-dir>/releases/v<version>/. pages.yml then signs
// the index with scripts/sign-index.sh.
//
// <withdrawn.json> (web/releases/withdrawn.json) lists the releases no one
// should install, as `[{ "version", "reason", "use" }]`. A withdrawn release
// moves from `releases` to `withdrawn` in the index, so a Kix that reads only
// `releases` never chooses it, and it is never `latest`. Its entry keeps the
// release's fields and files, so a project that names that version exactly
// can still install it and move off it. The script stops on an entry that
// names no listed release, has no reason, or whose `use` is not a newer
// listed release that is still current.
//
// The index shape is a contract with every shipped Kix (`kix::release::index`
// in cli/kix/src/release/) and with web/public/install, which reads it with
// sed. Add fields freely, since readers skip fields they do not know. Changing
// or removing a field needs a new `schema`.
//
// A prerelease, such as v0.9.0-rc.1, is listed with `"prerelease": true` and
// is never `latest`, so only someone who names it installs it.
//
// `generated` is the current time, or SOURCE_DATE_EPOCH when it is set.
// `expires` is LIFETIME_DAYS later. Kix refuses an expired index, so the
// site must be built and signed again before then. pages.yml runs daily.

import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const SCHEMA = 'kix.run/releases/v1';

/** How long an index stays current after it is generated. */
export const LIFETIME_DAYS = 7;

const TAG = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;
const ARCHIVE = /^kix-(.+)\.tar\.gz$/;
const SUMS_LINE = /^([0-9a-f]{64}) [ *](.+)$/;

/**
 * Parse a SHA256SUMS.sig file. Return `{ keyid, signature }`, or null when
 * the text is not a version 1 signature file over a 64-byte Ed25519
 * signature.
 */
export function parseSignature(text) {
  const lines = text.replace(/\r?\n$/, '').split(/\r?\n/);
  if (lines.length !== 3 || lines[0] !== 'kix-release-signature v1') {
    return null;
  }
  const keyid = lines[1].match(/^keyid=([0-9a-f]{8})$/);
  const signature = lines[2].match(/^signature=([A-Za-z0-9+/]{86}==)$/);
  if (!keyid || !signature || Buffer.from(signature[1], 'base64').length !== 64) {
    return null;
  }
  return { keyid: keyid[1], signature: signature[1] };
}

/**
 * Return the systems a SHA256SUMS file has an archive for, sorted, or null
 * when a line is not `<sha256>  <file>`.
 */
export function parseSystems(text) {
  const systems = [];
  for (const line of text.split(/\r?\n/)) {
    if (line === '') {
      continue;
    }
    const entry = line.match(SUMS_LINE);
    if (!entry) {
      return null;
    }
    const archive = entry[2].match(ARCHIVE);
    if (archive) {
      systems.push(archive[1]);
    }
  }
  return systems.sort();
}

/**
 * Compare two versions the way semver does: `<major>.<minor>.<patch>`
 * numerically, then a prerelease before its release, then prerelease
 * identifiers in turn, numeric ones numerically and below text ones.
 */
export function compareVersions(a, b) {
  const [coreA, preA] = splitPre(a);
  const [coreB, preB] = splitPre(b);
  const pa = coreA.split('.').map(Number);
  const pb = coreB.split('.').map(Number);
  for (let i = 0; i < 3; i += 1) {
    if (pa[i] !== pb[i]) {
      return pa[i] - pb[i];
    }
  }
  if (preA === null || preB === null) {
    return (preA === null ? 1 : 0) - (preB === null ? 1 : 0);
  }
  const ia = preA.split('.');
  const ib = preB.split('.');
  for (let i = 0; i < Math.min(ia.length, ib.length); i += 1) {
    const order = compareIdentifiers(ia[i], ib[i]);
    if (order !== 0) {
      return order;
    }
  }
  return ia.length - ib.length;
}

function splitPre(version) {
  const dash = version.indexOf('-');
  return dash === -1 ? [version, null] : [version.slice(0, dash), version.slice(dash + 1)];
}

function compareIdentifiers(a, b) {
  const numeric = /^\d+$/;
  if (numeric.test(a) && numeric.test(b)) {
    return Number(a) - Number(b);
  }
  if (numeric.test(a) !== numeric.test(b)) {
    return numeric.test(a) ? -1 : 1;
  }
  return a < b ? -1 : a > b ? 1 : 0;
}

function generatedAt(env) {
  const epoch = env.SOURCE_DATE_EPOCH;
  return epoch ? new Date(Number(epoch) * 1000) : new Date();
}

function stamp(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// The install script reads the index with sed after deleting whitespace and
// splitting at braces, so a reason must not hold a quote, a backslash, or a
// brace.
const REASON = /^[^"\\{}\r\n]+$/;

/**
 * Check the entries of withdrawn.json against the releases the index lists.
 * Return them in index form. Throw on the first entry that is wrong, because
 * a typo would leave a broken release installable.
 */
export function checkWithdrawn(entries, releases) {
  if (!Array.isArray(entries)) {
    throw new Error('withdrawn.json must be a list');
  }
  const listed = new Set(releases.map((r) => r.version));
  const versions = new Set(entries.map((e) => e?.version));
  return entries.map((entry) => {
    const { version, reason, use } = entry ?? {};
    const name = `withdrawn.json entry ${JSON.stringify(version)}`;
    if (typeof version !== 'string' || !listed.has(version)) {
      throw new Error(`${name} names no release in the index`);
    }
    if (typeof reason !== 'string' || !REASON.test(reason.trim())) {
      throw new Error(`${name} needs a reason: one line with no quote, backslash, or brace`);
    }
    if (
      typeof use !== 'string' ||
      !listed.has(use) ||
      versions.has(use) ||
      compareVersions(use, version) <= 0
    ) {
      throw new Error(`${name} needs "use": a newer release in the index that is not withdrawn`);
    }
    return { version, reason: reason.trim(), use };
  });
}

function readIfFile(path) {
  return existsSync(path) && statSync(path).isFile() ? readFileSync(path, 'utf8') : null;
}

/**
 * Read the releases under `src` and return `{ index, files }`: the index
 * object and the `[from, to]` copies (relative to the output directory) it
 * refers to. Every skipped release is reported through `warn`.
 */
export function collect(src, { env = process.env, warn = () => {}, withdrawn = [] } = {}) {
  const releases = [];
  const files = [];
  const tags = existsSync(src) ? readdirSync(src).sort() : [];

  for (const tag of tags) {
    const dir = join(src, tag);
    if (!statSync(dir).isDirectory()) {
      continue;
    }
    const match = tag.match(TAG);
    if (!match) {
      warn(`skipping ${tag}: not a v<major>.<minor>.<patch>[-<prerelease>] release`);
      continue;
    }
    const version = tag.slice(1);
    const sums = readIfFile(join(dir, 'SHA256SUMS'));
    const sig = readIfFile(join(dir, 'SHA256SUMS.sig'));
    if (sums === null || sig === null) {
      warn(`skipping ${tag}: it has no ${sums === null ? 'SHA256SUMS' : 'SHA256SUMS.sig'}`);
      continue;
    }
    if (!parseSignature(sig)) {
      warn(`skipping ${tag}: SHA256SUMS.sig is not a kix-release-signature v1 file`);
      continue;
    }
    const systems = parseSystems(sums);
    if (systems === null) {
      warn(`skipping ${tag}: SHA256SUMS has a line that is not "<sha256>  <file>"`);
      continue;
    }
    if (systems.length === 0) {
      warn(`skipping ${tag}: SHA256SUMS lists no kix-<system>.tar.gz archive`);
      continue;
    }

    const release = { version };
    if (match[4] !== undefined) {
      release.prerelease = true;
    }
    const date = readIfFile(join(dir, 'date'))?.trim();
    if (date && /^\d{4}-\d{2}-\d{2}$/.test(date)) {
      release.date = date;
    } else if (date !== undefined) {
      warn(`${tag}: ignoring date "${date}", which is not YYYY-MM-DD`);
    }
    release.systems = systems;
    release.sums = `/releases/${tag}/SHA256SUMS`;
    release.signature = `/releases/${tag}/SHA256SUMS.sig`;
    release.download = `/download/${version}/`;
    releases.push(release);
    files.push([join(dir, 'SHA256SUMS'), join('releases', tag, 'SHA256SUMS')]);
    files.push([join(dir, 'SHA256SUMS.sig'), join('releases', tag, 'SHA256SUMS.sig')]);
  }

  const pulled = checkWithdrawn(withdrawn, releases).sort((a, b) =>
    compareVersions(b.version, a.version),
  );
  const isPulled = (version) => pulled.some((w) => w.version === version);
  // The withdrawn entry leads with the fields the install script and Kix
  // match on, then carries the release's own fields.
  const withdrawnEntries = pulled.map((w) => {
    const { version, ...files } = releases.find((r) => r.version === w.version);
    return { ...w, ...files };
  });
  const current = releases.filter((r) => !isPulled(r.version));
  current.sort((a, b) => compareVersions(b.version, a.version));
  if (current.length === 0) {
    warn('no release has a signed SHA256SUMS, so the index lists none');
  }
  const generated = generatedAt(env);
  const expires = new Date(generated.getTime() + LIFETIME_DAYS * 24 * 60 * 60 * 1000);
  const index = {
    schema: SCHEMA,
    generated: stamp(generated),
    expires: stamp(expires),
    latest: current.find((r) => !r.prerelease)?.version ?? null,
    releases: current,
    withdrawn: withdrawnEntries,
  };
  return { index, files };
}

/** Write the index and the per-release files under `out`. Return the index. */
export function generate(src, out, options = {}) {
  const { index, files } = collect(src, options);
  mkdirSync(join(out, 'releases'), { recursive: true });
  for (const [from, to] of files) {
    mkdirSync(join(out, to, '..'), { recursive: true });
    copyFileSync(from, join(out, to));
  }
  writeFileSync(join(out, 'releases', 'index.json'), `${JSON.stringify(index, null, 2)}\n`);
  return index;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [src, out, withdrawnFile] = process.argv.slice(2);
  if (!src || !out) {
    console.error('usage: node release-index.mjs <src-dir> <out-dir> [<withdrawn.json>]');
    process.exit(2);
  }
  const withdrawn = withdrawnFile ? JSON.parse(readFileSync(withdrawnFile, 'utf8')) : [];
  const index = generate(src, out, {
    withdrawn,
    warn: (message) => console.error(`release-index: ${message}`),
  });
  const listed = index.releases.map((release) => release.version).join(', ') || 'none';
  console.log(`release-index: wrote ${join(out, 'releases', 'index.json')} (releases: ${listed})`);
}
