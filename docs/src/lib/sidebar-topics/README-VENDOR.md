# Vendored `starlight-sidebar-topics`

This is a local copy of [HiDeoo/starlight-sidebar-topics](https://github.com/HiDeoo/starlight-sidebar-topics)
(MIT-licensed, see `LICENSE`). It was vendored because the upstream
plugin is structurally incompatible with `starlight-versions`: both
want to own `starlightConfig.sidebar`, and the ordering needed to make
them coexist requires modifications to one of them. Upstream issue:
<https://github.com/HiDeoo/starlight-versions/issues/27>.

## Modifications

Three narrow changes vs. upstream `0.7.1`. Search for `VENDOR MOD` in
the source.

1. **`index.ts` — dropped sidebar-already-configured guard.** The
   upstream plugin throws if `starlightConfig.sidebar` is already set.
   We removed the throw so the plugin composes with anything that
   touches the sidebar later in `config:setup`. As long as topics is
   *first* in the `plugins:` array, this code path can't fire.

2. **`index.ts` — changed `addRouteMiddleware` order from `pre` to
   `post`.** Starlight runs middlewares in three buckets: `pre →
   default → post`. `starlight-versions` registers its middleware at
   `default` (no order set) and unwraps the per-version sidebar shell
   to expose just the current version's items. Topics needs to read
   that unwrapped shape, so it must run *after* versions —
   i.e., `post`.

3. **`middleware.ts` — topic switcher inherits the current page's
   version prefix.** Upstream renders topic buttons with the
   statically-configured `topic.link` (e.g. `/tutorials/`). When the
   reader is on `/docs/v0.1/foo`, clicking a topic should take them
   to `/docs/v0.1/tutorials/`, not back to `/docs/tutorials/`. We
   detect the version slug from `entry.id` with a regex
   (`^v\d+(\.\d+)*$`) and prepend it to each topic's link in
   `getRouteData`. If the project switches to a different version
   slug shape, update the regex.

We also rewrote the bare specifiers `'starlight-sidebar-topics/middleware'`
and `'starlight-sidebar-topics/overrides/Sidebar.astro'` to local file
URLs (`new URL('./middleware.ts', import.meta.url).href` etc.) since
this code no longer lives at a package import path.

## Upgrading

To pull in a newer upstream release:

1. Diff `node_modules/starlight-sidebar-topics` (after `npm install`)
   against `src/lib/sidebar-topics/`.
2. Apply non-conflicting changes.
3. Re-verify the two `VENDOR MOD` blocks survive the merge.
4. Re-run `npm run build` and confirm the `/docs/v0.1/` pages still
   render with both the topic switcher and the version selector.

Upstream cadence is roughly one release per few months. If a major
restructuring lands and re-applying the mods becomes painful, consider
whether `starlight-versions` has shipped native topics compatibility
(<https://github.com/HiDeoo/starlight-versions/issues/27>) and just
return to the upstream package.
