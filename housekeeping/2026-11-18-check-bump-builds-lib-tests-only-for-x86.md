# 2026-11-18 · `scripts/check-bump.sh` · The library tests build only for x86_64-linux, so the check fails on an arm64 host.

The script runs `nix build .#checks.x86_64-linux.kix-lib-tests`. On the aarch64 runner it stops with `Reason: platform mismatch`, so every bump fails here before the other checks report. The flake defines the same check for `aarch64-linux` (`flake.nix`, `libTests`). Fix the script to use the host system, or to run both.
