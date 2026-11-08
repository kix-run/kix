// Markdown content negotiation for agentic tools.
//
// Cloudflare Pages runs this file as the Worker for the whole site when
// it is present in the deployed directory ("advanced mode"). Pages does
// not upload it as a static asset. It lives in web/public/ so Vite copies
// it to web/dist/, which the deploy step merges into the site root.
//
// Every docs page has a Markdown twin at the sibling `.md` URL (or
// `/docs/index.md` for `/docs/`), emitted by starlight-llms-txt. When a
// client sends `Accept: text/markdown` for a docs URL, this Worker serves
// the Markdown twin; when a client sends `Accept: text/markdown` for the
// site root (`/`), it serves `/llms.txt`.
//
// Two discovery mechanisms are in play and cover different clients:
//
//   - Accept: text/markdown (handled here) covers Claude Code, Cursor,
//     GitHub Copilot Chat, Copilot CLI, and OpenCode.
//   - <link rel="alternate" type="text/markdown"> and
//     <link rel="describedby" href="/llms.txt"> (emitted by
//     docs/src/components/Head.astro and web/src/layouts/Base.astro)
//     cover clients like Codex CLI that fetch HTML without negotiating.
//
// Browsers never send text/markdown, so they are unaffected.
//
// The Worker also answers `/download/<version>/<file>`, where Kix and the
// install script fetch release archives, with a redirect to wherever the
// archives are stored. They verify every archive against the signed
// SHA256SUMS that kix.run serves under /releases/, so the storage host
// carries no trust. Moving the archives changes DOWNLOAD_ORIGIN here and the
// fetch in .github/workflows/pages.yml, and no shipped Kix.

const DOCS_PREFIX = '/docs/';

const DOWNLOAD_ORIGIN = 'https://github.com/kix-run/kix-releases/releases/download/';
// The version is a release such as 0.8.4, or a prerelease such as 0.9.0-rc.1.
const DOWNLOAD_PATH = /^\/download\/(\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)\/([A-Za-z0-9_-][A-Za-z0-9._-]*)$/;

// Each Kix version's docs are a separate build with its own root: /docs for
// the latest release, /docs/main for main, and /docs/v<major>.<minor> for
// an older minor release (.github/workflows/pages.yml).
const VERSION_ROOT = /^\/docs(?:\/(?:main|v\d+\.\d+))?(?=\/|$)/;

/**
 * True when the client explicitly asked for Markdown.
 *
 * Matches the media type as a whole token so that a hypothetical
 * `text/markdownish` cannot trigger it. A wildcard-only Accept header
 * (curl's default) deliberately does not match: only an explicit
 * preference for Markdown counts.
 */
function prefersMarkdown(accept) {
  return /(?:^|[\s,])text\/markdown(?=$|[\s,;])/i.test(accept || '');
}

/**
 * Map a request pathname to its Markdown twin.
 *
 *   /                 -> /llms.txt
 *   /docs/            -> /docs/index.md
 *   /docs/how-to/     -> /docs/how-to.md
 *   /docs/how-to/x/   -> /docs/how-to/x.md
 *   /docs/main/       -> /docs/main/index.md
 */
function markdownPathFor(pathname) {
  if (pathname === '/' || pathname === '') {
    return '/llms.txt';
  }
  const path = pathname.replace(/\/+$/, '');
  const root = path.match(VERSION_ROOT)[0];
  return path === root ? `${root}/index.md` : `${path}.md`;
}

/** Add `Accept` to Vary without duplicating an existing entry. */
function withVaryAccept(response) {
  const headers = new Headers(response.headers);
  const vary = headers.get('vary');
  const alreadyVaries = (vary || '')
    .split(',')
    .some((token) => token.trim().toLowerCase() === 'accept');

  if (!alreadyVaries) {
    headers.set('vary', vary ? `${vary}, Accept` : 'Accept');
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/** Redirect a release download to the storage host, or return null for any other path. */
function downloadRedirect(url) {
  const match = url.pathname.match(DOWNLOAD_PATH);
  if (!match) {
    return null;
  }
  const [, version, file] = match;
  return new Response(null, {
    status: 302,
    headers: {
      location: `${DOWNLOAD_ORIGIN}v${version}/${file}`,
      'cache-control': 'no-store',
    },
  });
}

/** A route with a Markdown representation worth serving, not the `.md` asset itself. */
function isNegotiablePage(url) {
  if (url.pathname === '/') {
    return true;
  }
  if (!url.pathname.startsWith(DOCS_PREFIX) || url.pathname.endsWith('.md')) {
    return false;
  }
  return VERSION_ROOT.test(url.pathname.replace(/\/+$/, ''));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const readOnly = request.method === 'GET' || request.method === 'HEAD';

    const download = readOnly ? downloadRedirect(url) : null;
    if (download) {
      return download;
    }

    // Pages may not apply _headers to responses that pass through this
    // Worker, so the install script and the release index get their headers
    // here. The script must arrive as text for `curl | sh`, and both must
    // refresh within minutes of a release.
    if (readOnly && (url.pathname === '/install' || url.pathname.startsWith('/releases/'))) {
      const asset = await env.ASSETS.fetch(request);
      if (!asset.ok) {
        return asset;
      }
      const headers = new Headers(asset.headers);
      if (url.pathname === '/install') {
        headers.set('content-type', 'text/plain; charset=utf-8');
      }
      headers.set('cache-control', 'public, max-age=300');
      return new Response(asset.body, { status: asset.status, statusText: asset.statusText, headers });
    }

    if (readOnly && isNegotiablePage(url) && prefersMarkdown(request.headers.get('accept'))) {
      const markdownUrl = new URL(url);
      markdownUrl.pathname = markdownPathFor(url.pathname);

      const markdown = await env.ASSETS.fetch(new Request(markdownUrl, request));
      if (markdown.ok) {
        const headers = new Headers(markdown.headers);
        headers.set('content-type', 'text/markdown; charset=utf-8');
        return withVaryAccept(
          new Response(markdown.body, {
            status: markdown.status,
            statusText: markdown.statusText,
            headers,
          }),
        );
      }
      // No twin (the 404 page is the one docs route without one).
      // Fall through and serve the HTML.
    }

    const response = await env.ASSETS.fetch(request);

    // The HTML representation of a negotiable page depends on Accept, so
    // caches must not serve one representation for the other.
    return isNegotiablePage(url) ? withVaryAccept(response) : response;
  },
};
