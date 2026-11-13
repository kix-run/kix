# 2026-11-13 · `cli/kix-cli/src/cli/` · `--offline` means "do not contact the cluster" on `kix plan` and `kix deploy`, and "do not contact registries" on `kix pin check`.

`cli/plan.rs:109` and `cli/pin.rs:125` define the two flags. A user who learns one meaning applies it to the other command. Each help text should say which network it avoids.
