# 2026-11-07 · `cli/flake-integration.nix` · The Nix package of Kix (`packages.<system>.kix`) is built with crane without `cargo auditable`, so its binary carries no crate list.

The release archives do carry one. A user who installs Kix through Nix, nix-darwin, or NixOS cannot run `cargo audit bin` on it the same way.
