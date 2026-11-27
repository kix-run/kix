# 2026-11-24 · `cli/kix-cli/src/commands/export.rs` · `kix export` includes the `kube-system` Namespace in plain YAML meant for another tool.

By default, `kix export` on a `kind`-flavored cluster writes `_cluster/Namespace-kube-system.yaml`. When Flux applies that export and its `Kustomization` is later removed with pruning enabled, Flux tries to delete `kube-system`, which the API server refuses, and the `Kustomization` stays stuck until someone suspends it. `move-from-flux-to-kix-in-phases.mdx` tells the reader to delete the file by hand, and `export-plain-yaml.mdx` does not mention it.
