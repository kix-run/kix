# 2026-11-13 · `cli/kix-cli/src/removed.rs` · Registering a removed flag moves its command to the end of the command list.

`add_flag` calls clap's `mut_subcommand`, which takes the subcommand out and pushes it back last. `kix --help` still lists commands in their original order, but `get_subcommands()` does not, so `cli_surface.snap` shows `kix status` moved to the bottom once `status --operator` became a stub. A reviewer then sees every line of a command removed and added again, which hides what really changed.
