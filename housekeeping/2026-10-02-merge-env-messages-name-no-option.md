# 2026-10-02 · `kix/lib/vocab/compose.nix` · `kix.mergeEnv` has no `option` argument, so a refused variable is reported as "env sets X" even when the package's option is `node.env` or `controller.env`.

`kix.guardArgs` takes `option` and names it in the message; `mergeEnv`
always writes `env`. A package with several env options cannot say which one
the user set except by repeating the option name in each group's `fix` text,
which zfs-localpv does ("Remove it from node.env.").

- Hit again 2026-10-02 by `kix/packages/mayastor`, which has ten env options and names the option in each group's `fix` text through its `env` helper in `common.nix`.
