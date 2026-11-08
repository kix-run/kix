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

const DOCS_PREFIX = '/docs/';

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
    return '/docs/llms.txt';
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
