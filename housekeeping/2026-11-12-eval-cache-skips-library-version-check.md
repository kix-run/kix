# 2026-11-12 · `cli/kix-core/src/eval` · A hit in Kix's eval cache skips the check that Kix can build the project's library.

`check_library` runs only inside `eval_activation_index`, and a cache hit returns before it. The cache key covers the project's files and `flake.lock`, not the running Kix. So after Kix 0.9.0 built a project, Kix 0.10.0-rc.1 ran `kix check` and `kix build` on the same 0.9.0 library and passed. With `--no-cache` it refused, with the right message. Seen on the Lithus monorepo's `li1-kix`.
