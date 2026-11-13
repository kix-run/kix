# 2026-11-12 · `cli/kix-cli/src/plan/render.rs` · The hash-mismatch advice guesses which instance declares the SOPS file.

`own_instance` picks the instance whose name equals the refused Secret's name, since a `packages.secret` instance names its Secret after itself. The plan document does not say which package an instance runs, so a database instance that also renders a Secret with its own name would be named as the place to change `hash`.
