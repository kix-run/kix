# 2026-10-03 · `flake.nix` · The flake dev shell keys `CARGO_TARGET_DIR` on the directory the shell was entered from, so each subdirectory gets its own target dir.

`devenv.nix` keys the target dir on `config.devenv.root`, the checkout. The
flake's `shellHook` (`flake.nix`, the `kix-cargo-target` export) uses `$PWD`
instead. Entering the shell from `cli/`, `cli/kix-cli/`, or `housekeeping/`
makes three directories of about 5 GB each under `~/.cache/kix-cargo-target/`,
each one a full rebuild. One session left six of them and took the Nix store
volume below the guard's 12 GB floor.
