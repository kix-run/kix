# 2026-09-20 · Live documentation captures · The PTY wrapper fails on Linux.

`nix run ./docs#regen-captures -- --group how-to/adoption-ssa-conflicts --apply`
fails during preparation with `script: unrecognized option '--no-cache'`.
`docs/nix/captures-live.nix` invokes `script -q /dev/null command ...`, which
uses the macOS argument format. Linux util-linux `script` expects the command
through `-c`. The failure prevents live examples from being refreshed on Linux.
- Fix landed 2026-09-20, unverified: `docs/nix/captures-live.nix` now wraps every invocation in a `ptyrun` helper that uses util-linux `script --command` on Linux and the BSD form on macOS. Nothing has run it against a live kind cluster yet, so the entry stays open until a Linux capture run passes.
