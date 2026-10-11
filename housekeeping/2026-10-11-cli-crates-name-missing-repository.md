# 2026-10-11 · `cli/Cargo.toml` · The CLI workspace points `repository` at a GitHub repository that does not exist.

`[workspace.package]` sets `repository = "https://github.com/kixpkgs/kixpkgs"`, and `cli/flake-integration.nix` uses the same URL as the `kix` package's `homepage`. The repository is kix-run/kixpkgs, and it is private, so neither URL helps a reader of the published binaries at kix-run/kix-releases.
