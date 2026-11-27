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

test('redirects a prerelease download', async () => {
  const { response } = await get('/download/0.9.0-rc.1/kix-aarch64-darwin.tar.gz');
  assert.equal(response.status, 302);
  assert.equal(
    response.headers.get('location'),
    'https://github.com/kix-run/kix-releases/releases/download/v0.9.0-rc.1/kix-aarch64-darwin.tar.gz',
  );
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
    '/download/0.9.0-/kix-x86_64-linux.tar.gz',
    '/download/0.9.0-rc..1/kix-x86_64-linux.tar.gz',
    '/download/0.9.0-rc.1/../x',
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

test('serves the install script as text, release files with a short cache, and the index revalidated', async () => {
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
  assert.equal(index.headers.get('cache-control'), 'public, no-cache');
  assert.equal(index.headers.get('content-type'), 'application/octet-stream');
  const sig = await worker.fetch(new Request('https://kix.run/releases/index.json.sig'), env);
  assert.equal(sig.headers.get('cache-control'), 'public, no-cache');
  const sums = await worker.fetch(new Request('https://kix.run/releases/v0.8.4/SHA256SUMS'), env);
  assert.equal(sums.headers.get('cache-control'), 'public, max-age=300');
  assert.deepEqual(seen, [
    '/install',
    '/releases/index.json',
    '/releases/index.json.sig',
    '/releases/v0.8.4/SHA256SUMS',
  ]);
});

// Stand in for the network: record each forwarded request and answer 202.
async function forward(path, { method = 'GET', headers = {}, body } = {}) {
  const sent = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    const request = new Request(input, init);
    sent.push({ request, body: await request.text() });
    return new Response(null, { status: 202 });
  };
  try {
    const env = assets();
    const response = await worker.fetch(new Request(`https://kix.run${path}`, { method, headers, body }), env);
    return { response, sent, seen: env.seen };
  } finally {
    globalThis.fetch = realFetch;
  }
}

test('forwards a page view to the analytics host with the visitor address', async () => {
  const { response, sent, seen } = await forward('/p/event', {
    method: 'POST',
    headers: {
      'cf-connecting-ip': '203.0.113.7',
      'content-type': 'text/plain',
      'user-agent': 'Visitor/1.0',
      cookie: 'a=b',
    },
    body: '{"n":"pageview"}',
  });
  assert.equal(response.status, 202);
  assert.deepEqual(seen, []);
  assert.equal(sent.length, 1);
  const { request, body } = sent[0];
  assert.equal(request.url, 'https://p.kix.run/p/event');
  assert.equal(request.method, 'POST');
  assert.equal(request.headers.get('x-visitor-ip'), '203.0.113.7');
  assert.equal(request.headers.get('user-agent'), 'Visitor/1.0');
  assert.equal(request.headers.get('content-type'), 'text/plain');
  assert.equal(request.headers.get('cookie'), null);
  assert.equal(body, '{"n":"pageview"}');
});

test('forwards the analytics script', async () => {
  const { response, sent } = await forward('/p/script.js', { headers: { 'cf-connecting-ip': '203.0.113.7' } });
  assert.equal(response.status, 202);
  assert.equal(sent[0].request.url, 'https://p.kix.run/p/script.js');
  assert.equal(sent[0].request.method, 'GET');
});

test('leaves other /p/ paths to the assets', async () => {
  const { sent, seen } = await forward('/p/other.js');
  assert.deepEqual(sent, []);
  assert.deepEqual(seen, ['/p/other.js']);
});
