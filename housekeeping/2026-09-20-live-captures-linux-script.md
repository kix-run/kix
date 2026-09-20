# 2026-09-20 · Live documentation captures · The PTY wrapper fails on Linux.

`nix run ./docs#regen-captures -- --group how-to/adoption-ssa-conflicts --apply`
fails during preparation with `script: unrecognized option '--no-cache'`.
`docs/nix/captures-live.nix` invokes `script -q /dev/null command ...`, which
uses the macOS argument format. Linux util-linux `script` expects the command
through `-c`. The failure prevents live examples from being refreshed on Linux.
