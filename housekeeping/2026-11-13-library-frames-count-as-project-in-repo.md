# 2026-11-13 · `cli/kix-core/src/eval/nix.rs` · In this repository, a cluster error shows frames from `kix/lib/`.

Kix keeps the stack frames that sit in the project, and here the project is the whole repository, library included. A missing attribute in `clusters/test-minimal.nix`, built from the root flake, shows three frames from `kix/lib/eval/resolve.nix` before the message. A user's project gets the library as an input, so it does not see this. Kix could leave out frames under the library's own folder if the library published it next to `kixLibrary.projectRoot`.
