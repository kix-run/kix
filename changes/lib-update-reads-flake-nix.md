+++
kind = "fixed"
+++
`kix lib update` now works after you follow its advice. When `flake.nix` pins the Kix library to a tag or reads it from a mirror, Kix tells you to change the input in `flake.nix` and run the command again. Before, the second run gave the same error, because Kix read the input from `flake.lock`, which still held the old entry. Kix now reads the input as `flake.nix` gives it, and writes `flake.lock` when the Kix library there is already the matching version.
