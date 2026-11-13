# 2026-11-13 · `cli/kix-cli/src/commands/` · `kix list resources` and `kix list images` live in `inspect.rs` and `images.rs`.

`commands/list.rs` (lines 99-100) sends both subcommands to files named after the old commands. Someone looking for the `list` code does not find it. Move them under `commands/list/`.
