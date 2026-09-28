# 2026-09-27 · `cli/kix/src/manifest/validate.rs` · `kix check` reports three validators it never runs as `pass`.

`kubeconform`, `pluto` and `kyverno` are placeholders that always return `passed: true` with the detail "skipped". The table still shows `pass` in the RESULT column, and `kix check --help` says "Validate: eval + schema + policy", so a reader assumes schema and policy validation ran. Either run the tools or report them as `skip`, and make the help text match.
