# 2026-11-21 · `cli/kix-core/src/eval/nix.rs` · Kix does not notice a cluster built by another Kix library when one flake merges two.

A `flake.nix` with two Kix library inputs can build one cluster with each and merge the `mkFlake` outputs. `check_library` reads one `kixLibrary.version` for the whole project, so it sees only the library whose outputs won the merge. Kix 0.10.0-rc.5 then built and would deploy a cluster that the 0.10.0-rc.4 library evaluated, with no error. The layout is unsupported, and nothing says so.
