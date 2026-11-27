import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import { checkLinks } from './check-links.mjs';

function makeFixture(run) {
  const root = mkdtempSync(join(tmpdir(), 'kix-check-links-'));
  try {
    mkdirSync(join(root, 'docs', 'scripts'), { recursive: true });
    mkdirSync(join(root, 'docs', 'src', 'content', 'docs', 'tutorials'), { recursive: true });
    mkdirSync(join(root, 'kix', 'packages', 'stable', 'grafana'), { recursive: true });
    mkdirSync(join(root, 'kix', 'packages', 'experimental', 'clickhouse'), { recursive: true });
    mkdirSync(join(root, 'dist', 'about'), { recursive: true });
    mkdirSync(join(root, 'dist', 'packages'), { recursive: true });

    writeFileSync(join(root, 'docs', 'scripts', 'package-catalog.py'), '# stub\n');
    writeFileSync(join(root, 'docs', 'src', 'content', 'docs', 'index.mdx'), '---\ntitle: Docs\n---\n');
    writeFileSync(
      join(root, 'docs', 'src', 'content', 'docs', 'tutorials', '01-orientation.mdx'),
      '---\ntitle: Orientation\n---\n',
    );
    writeFileSync(
      join(root, 'kix', 'packages', 'stable', 'grafana', 'default.nix'),
      '{ ... }: { meta = {\n    description = "Grafana";\n  };\n}\n',
    );
    writeFileSync(
      join(root, 'kix', 'packages', 'experimental', 'clickhouse', 'default.nix'),
      '{ ... }: { meta = {\n    description = "ClickHouse";\n  };\n}\n',
    );

    return run(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test('accepts valid internal routes, anchors, and /docs/main package catalog links', () => {
  makeFixture((root) => {
    writeFileSync(
      join(root, 'dist', 'about', 'index.html'),
      '<main id="main"><a href="#main">Skip</a><a href="/packages#catalog">Packages</a><a href="/docs/">Docs</a></main>',
    );
    writeFileSync(
      join(root, 'dist', 'packages', 'index.html'),
      '<main id="main"><section id="catalog">' +
        '<a href="/docs/main/reference/package-catalog/grafana/">grafana</a>' +
        '<a href="/docs/main/reference/package-catalog/experimental/clickhouse/">clickhouse</a>' +
        '<a href="https://github.com/kix-run">GitHub</a>' +
        '</section></main>',
    );

    const result = checkLinks({
      distDir: join(root, 'dist'),
      repoRoot: root,
      packagesTsPath: null,
    });
    assert.deepEqual(result.errors, []);
    assert.equal(result.checked, 5);
  });
});

test('rejects broken package links, wrong stability paths, and unversioned catalog links', () => {
  makeFixture((root) => {
    writeFileSync(
      join(root, 'dist', 'about', 'index.html'),
      '<main id="main">' +
        '<a href="/missing-page">Missing</a>' +
        '<a href="/packages#missing-anchor">Bad anchor</a>' +
        '</main>',
    );
    writeFileSync(
      join(root, 'dist', 'packages', 'index.html'),
      '<main id="main"><section id="catalog">' +
        '<a href="/docs/reference/package-catalog/grafana/">unversioned</a>' +
        '<a href="/docs/main/reference/package-catalog/clickhouse/">wrong stability</a>' +
        '<a href="/docs/main/reference/package-catalog/experimental/nonexistent/">missing pkg</a>' +
        '</section></main>',
    );

    const { errors } = checkLinks({
      distDir: join(root, 'dist'),
      repoRoot: root,
      packagesTsPath: null,
    });
    assert.equal(errors.length, 5);
    assert.match(errors[0], /broken internal link "\/missing-page"/);
    assert.match(errors[1], /missing id="missing-anchor"/);
    assert.match(errors[2], /must use \/docs\/main\/reference\/package-catalog/);
    assert.match(errors[3], /package "clickhouse" is experimental/);
    assert.match(errors[4], /missing experimental package/);
  });
});

test('verifies links directly against staged _site directory when --site-root is used', () => {
  makeFixture((root) => {
    const siteRoot = join(root, '_site');
    mkdirSync(join(siteRoot, 'packages'), { recursive: true });
    mkdirSync(join(siteRoot, 'docs', 'main', 'reference', 'package-catalog', 'grafana'), { recursive: true });
    writeFileSync(join(siteRoot, 'packages', 'index.html'), '<section id="catalog"></section>');
    writeFileSync(
      join(siteRoot, 'docs', 'main', 'reference', 'package-catalog', 'grafana', 'index.html'),
      '<h1>grafana</h1>',
    );

    writeFileSync(
      join(root, 'dist', 'about', 'index.html'),
      '<a href="/packages#catalog">ok</a>' +
        '<a href="/docs/main/reference/package-catalog/grafana/">ok</a>' +
        '<a href="/docs/main/reference/package-catalog/experimental/clickhouse/">missing in staged site</a>',
    );

    const { errors } = checkLinks({
      distDir: join(root, 'dist'),
      repoRoot: root,
      siteRoot,
      packagesTsPath: null,
    });
    assert.equal(errors.length, 1);
    assert.match(errors[0], /not found in staged site/);
  });
});
