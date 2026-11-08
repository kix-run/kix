import assert from 'node:assert/strict';
import { test } from 'node:test';

import worker from '../public/_worker.js';

// Stand in for the Pages asset server: record each request and answer 404.
function assets() {
  const seen = [];
  return {
    seen,
    ASSETS: {
      async fetch(request) {
        seen.push(new URL(request.url).pathname);
        return new Response('not found', { status: 404 });
      },
    },
  };
}

async function get(path, { method = 'GET', headers = {} } = {}) {
  const env = assets();
  const response = await worker.fetch(new Request(`https://kix.run${path}`, { method, headers }), env);
  return { response, seen: env.seen };
}

test('redirects a release download to the storage host', async () => {
  for (const method of ['GET', 'HEAD']) {
    const { response, seen } = await get('/download/0.8.4/kix-x86_64-linux.tar.gz', { method });
    assert.equal(response.status, 302);
    assert.equal(
      response.headers.get('location'),
      'https://github.com/kix-run/kix-releases/releases/download/v0.8.4/kix-x86_64-linux.tar.gz',
    );
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(seen, []);
  }
});

test('passes other download paths to the assets', async () => {
  for (const path of [
    '/download/../x',
    '/download/0.8.4/..',
    '/download/0.8.4/.hidden',
    '/download/0.8.4/a/b',
    '/download/0.8.4/',
    '/download/0.8/kix-x86_64-linux.tar.gz',
    '/download/v0.8.4/kix-x86_64-linux.tar.gz',
    '/download/0.8.4/kix%2fx',
  ]) {
    const { response, seen } = await get(path);
    assert.equal(response.status, 404, path);
    assert.equal(seen.length, 1, path);
  }
});

test('does not redirect a POST', async () => {
  const { response } = await get('/download/0.8.4/kix-x86_64-linux.tar.gz', { method: 'POST' });
  assert.equal(response.status, 404);
});

test('leaves other paths to the assets', async () => {
  for (const path of ['/install', '/releases/index.json', '/docs/']) {
    const { seen } = await get(path);
    assert.deepEqual(seen, [path]);
  }
});

test('still serves the Markdown twin of a docs page', async () => {
  const { seen } = await get('/docs/how-to/', { headers: { accept: 'text/markdown' } });
  assert.deepEqual(seen, ['/docs/how-to.md', '/docs/how-to/']);
});

test('serves the install script as text and the release index with a short cache', async () => {
  const seen = [];
  const env = {
    ASSETS: {
      async fetch(request) {
        seen.push(new URL(request.url).pathname);
        return new Response('body', { status: 200, headers: { 'content-type': 'application/octet-stream' } });
      },
    },
  };
  const install = await worker.fetch(new Request('https://kix.run/install'), env);
  assert.equal(install.headers.get('content-type'), 'text/plain; charset=utf-8');
  assert.equal(install.headers.get('cache-control'), 'public, max-age=300');
  const index = await worker.fetch(new Request('https://kix.run/releases/index.json'), env);
  assert.equal(index.headers.get('cache-control'), 'public, max-age=300');
  assert.equal(index.headers.get('content-type'), 'application/octet-stream');
  assert.deepEqual(seen, ['/install', '/releases/index.json']);
});
