# 2026-11-24 · `kix/lib/helm.nix` · `importChart` does not reject duplicate Helm flags in `extraFlags`.

Passing `--values`, `--namespace`, `--include-crds`, `--no-hooks`, or `--kube-version` in `extraFlags` changes what `helm template` renders instead of failing evaluation. Both `helmTemplateArgs` in `kix/lib/helm.nix` and `render` in `cli/kix-core/src/eval/helm.rs` append `extraFlags` without checking for flags Kix already passes. `docs/src/content/docs/reference/helm-and-imports.mdx` previously said these flags could not appear; it now warns against repeating them.
