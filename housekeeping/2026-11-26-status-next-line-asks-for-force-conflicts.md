# 2026-11-26 · `cli/kix-cli/src/commands/status/text.rs` · `kix status` still tells the user to run `kix deploy --reconcile --force-conflicts` to repair drift.

A plain `kix deploy` now puts back a missing object and takes back the changed fields of every object it applied, forcing only those (rule 3 in `plan/decide.rs`). The `Next:` line (around line 306) still names `--reconcile` and `--force-conflicts`, and `--force-conflicts` forces every apply of the run, so the advice takes more than the user needs.
