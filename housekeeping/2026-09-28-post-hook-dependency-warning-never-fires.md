# 2026-09-28 · `kix/lib/eval/instance.nix` · The post-hook dependency warning cannot fire for a hook with any dependency.

`postHookWarnings` asks whether a post-hook depends on something in the forward closure other than the hooks themselves. The forward closure is seeded with the hooks, so it already holds everything each hook references. Any hook with one dependency passes, even when nothing it references is the root or a `requires` entry. The `stackgres-database` Job depends only on its own Secrets and network policies, never on `root`, and gets no warning.
