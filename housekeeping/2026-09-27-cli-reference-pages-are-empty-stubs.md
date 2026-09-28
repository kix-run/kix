# 2026-09-27 · `docs/src/content/docs/reference/cli/` · 25 CLI reference pages are empty stubs with `description: TODO`.

`gc.mdx` and 24 siblings hold only front matter, yet the how-to guides link to them (for example "See [`kix gc`](/docs/reference/cli/gc/) for all flags and mode behavior"). A reader who follows the link finds nothing. Check with `grep -l 'description: TODO' docs/src/content/docs/reference/cli/*.mdx`.
