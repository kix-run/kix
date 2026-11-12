# 2026-11-12 · `cli/kix-cli/src/commands/upgrade` · `kix upgrade --to 0.10.0-rc.1` says no release matches, when the release exists and is a prerelease.

The message is "No Kix release for x86_64-linux matches `--to 0.10.0-rc.1`. Next: pass an available version". `plan.rs` drops prereleases on purpose, but the message does not say so, and it does not say how to try one (set `kix` in kix.toml and move the library input by hand).
