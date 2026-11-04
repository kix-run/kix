// Markdown content negotiation for agentic tools.
//
// Cloudflare Pages runs this file as the Worker for the whole site when
// it is present in the deployed directory ("advanced mode"). Pages does
// not upload it as a static asset. It lives in web/public/ so Vite copies
// it to web/dist/, which the deploy step merges into the site root.
//
// Every docs page already has a Markdown twin at the sibling `.md` URL,
// emitted by starlight-llms-txt. This serves that file when the client
// asks for Markdown, which is a large saving: the HTML for a typical
// how-to page is ~80 KB against ~2 KB of Markdown.
//
// Two different discovery mechanisms are in play, and they cover
// different clients:
//
//   - Accept: text/markdown (handled here) covers Claude Code, Cursor,
//     GitHub Copilot Chat, Copilot CLI and OpenCode.
//   - <link rel="alternate" type="text/markdown"> (emitted by
//     docs/src/components/Head.astro) is the only signal Codex CLI
//     reads, since it ignores the Accept header.
//
// Browsers never send text/markdown, so they are unaffected.

const DOCS_PREFIX = '/docs/';

// The docs root and the Diataxis quadrant roots are navigation pages:
// their source is frontmatter only, so the `.md` twin is a bare heading
// (`# How-to guides`, 17 bytes) while the HTML carries the sidebar
// listing every child page. Serving the twin for these would hand an
// agent less than the HTML does, and an agent with no list of pages
// invents URLs. Serve HTML here and let the sidebar do the work.
//
// docs/src/components/Head.astro withholds its <link rel="alternate">
// for the same routes. Keep the two lists in step. Paths are relative to
// the version's root (see VERSION_ROOT).
const NAVIGATION_ONLY = new Set(['', '/tutorials', '/how-to', '/reference', '/explanation']);

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
 * Map a docs page URL to its Markdown twin.
 *
 *   /docs/            -> /docs/index.md
 *   /docs/how-to/     -> /docs/how-to.md
 *   /docs/how-to/x/   -> /docs/how-to/x.md
 *   /docs/main/       -> /docs/main/index.md
 */
function markdownPathFor(pathname) {
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

/** A docs page with a Markdown twin worth serving, not the twin itself. */
function isNegotiablePage(url) {
  if (!url.pathname.startsWith(DOCS_PREFIX) || url.pathname.endsWith('.md')) {
    return false;
  }
  const path = url.pathname.replace(/\/+$/, '');
  return !NAVIGATION_ONLY.has(path.slice(path.match(VERSION_ROOT)[0].length));
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

    // The HTML representation of a docs page now depends on Accept, so
    // caches must not serve one representation for the other.
    return isNegotiablePage(url) ? withVaryAccept(response) : response;
  },
};
