# 2026-09-27 · `cli/kix-cli/src/cli.rs` · A global flag that a command ignores is accepted without a word.

`kix drift --flake ../infra` and `kix deploy demo -o json` run as if the flag were absent. The subcommand's `--help` hides such flags, but nothing warns a user who passes one. `SCOPED_GLOBALS` already knows which commands read which flag, so a warning is possible; wrappers such as `docs/nix/captures-live.nix` pass `--context`, `--flake` and `--no-cache` to every command, so an error would break them.
