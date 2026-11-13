+++
kind = "error"
cli = ["kix lib update"]
id = "K6054"
+++
`kix lib update` is removed, and stops with `[K6054]`. Run `kix upgrade --to <version>` with the version the project is on, such as `kix upgrade --to 0.10.0`. It moves the Kix library in `flake.lock`, and changes the tag in `flake.nix` when the input names one. Kix now finds the library input by its name in `flake.nix` (`kix`, `kixpkgs`, or `library-input` in `kix.toml`), so a mirror or a fork moves like any other input. An input that follows a branch or a commit is now left alone and checked: before, Kix locked it to the release tag, so `flake.lock` disagreed with `flake.nix`. When the branch holds a Kix library that the version cannot build, Kix stops and says to point the input at the tag. A Kix library that comes only through another flake's input is no longer moved. Kix stops and names the lines to add to `flake.nix`, such as `inputs.platform.inputs.kix.follows = "kix";`.
