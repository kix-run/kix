# 2026-09-27 · `cli/kix-cli/src/commands/completions.rs` · `kix completions bash | head` panics with "failed to write completion file: Broken pipe".

`clap_complete::generate` panics when stdout closes early, and Kix prints a Rust panic and backtrace hint instead of exiting quietly. Any pipeline that reads only part of the script hits it.
