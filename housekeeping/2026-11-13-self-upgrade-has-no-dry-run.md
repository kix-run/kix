# 2026-11-13 · `cli/kix-cli/src/cli/project.rs` · `kix self upgrade` has no `--dry-run`, though the change record calls `--dry-run` the one flag for changing nothing.

`SelfCommand::Upgrade` (line 62) takes no arguments. `changes/cli-upgrade-verbs.md` says "`--dry-run` the one flag for changing nothing", and `kix upgrade` and `kix self prune` have it. A user who tries `kix self upgrade --dry-run` gets an unknown-flag error.
