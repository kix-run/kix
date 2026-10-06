# 2026-10-06 · `docs/` Markdown twins · The `v0.1` Markdown twins contain the current pages, not the v0.1 snapshot.

In a `nix build ./docs#site` output, `v0.1/tutorials/05-basic-graph-and-deploy-loop.md`
contains the `<Loop>` block that exists only in the current
`tutorials/05-basic-graph-and-deploy-loop.mdx`; the v0.1 source has no such
block. An agent that reads a v0.1 page through its twin (Copy as Markdown, the
`<link rel="alternate">` in `Head.astro`, or `_worker.js` negotiation) gets the
latest docs. Look at how `starlight-page-actions` (its `viteStaticCopy` rename)
and `starlight-llms-txt` each write `.md` files into the same paths.
