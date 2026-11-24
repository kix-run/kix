# 2026-11-24 · `kix/lib/helm.nix` · `importChart`'s `extraFlags` accepts flags Kix already passes, such as `--values` and `--namespace`.

`helmTemplateArgs` appends `extraFlags` unchecked, and the Rust renderer does the same (`cli/kix-core/src/eval/helm.rs`, `render`). The reference page used to say these flags "cannot" appear; it now says not to repeat them. A repeated `--values` or `--kube-version` silently changes the render instead of failing evaluation.
