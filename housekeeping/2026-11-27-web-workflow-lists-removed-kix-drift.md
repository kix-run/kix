# 2026-11-27 · `web/src/components/sections/Deploying.astro` · The workflow page still lists the removed `kix drift` command.

`kix drift` was removed in 0.10 in favor of `kix status [cluster] --check drift` and now stops with `[K6116]`. `web/src/components/sections/Deploying.astro` still advertises `kix drift` in the rollout command grid on `/workflow`.
