# 2026-11-13 · `cli/kix/src/cluster/stops.rs` · The required stops are listed twice: by hand in `REQUIRED_STOPS` and as `required-stop = true` in the change records.

`REQUIRED_STOPS` (line 14) is a constant the release skill edits. `kix upgrade` reads the records instead (`required_stop` in `cli/kix-cli/src/commands/upgrade/plan.rs:104`). If the two disagree, `kix upgrade` stops at one release and `kix deploy` refuses at another. Both lists are empty today, so add a test that compares `changes/<version>/*.md` with `REQUIRED_STOPS` before the first stop lands.
