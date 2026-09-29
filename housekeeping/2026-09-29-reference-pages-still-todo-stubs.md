# 2026-09-29 · `docs/src/content/docs/reference` · 73 reference pages are still stubs that say only `description: TODO`.

A reader looking up how a field behaves finds nothing and falls back to reading `kix/lib`. It cost time on 2026-09-29: `instance-schema/extradeps.mdx` is one of them, and whether a cluster can make one instance wait for another's Secret had to be worked out from the source. List them with `grep -rl '^description: TODO' docs/src/content/docs/reference`.
