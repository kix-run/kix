# 2026-09-27 · `cli/kix-cli/src/commands/completions.rs` · Shell completions still offer global flags that a command ignores.

`kix completions bash`, `zsh` and `fish` offer `--context`, `--flake` and the rest after `kix completions` and `kix drift`, although their `--help` no longer lists them. clap_complete's static generators include arguments marked `hide`. A user who tabs through the flags still meets ones that do nothing there.
