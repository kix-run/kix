# 2026-11-04 · `docs/` · Every docs page asks for `/docs/favicon.svg`, which the docs build does not contain.

Starlight links the favicon under the docs base, but `docs/` has no `public/favicon.svg`; only `web/public/favicon.svg` exists, at the site root. Browsers log a 404 on each docs page and show no icon. Seen serving the docs builds locally; each version's build (`/docs/main/`, `/docs/v0.5/`) asks for its own copy too.
