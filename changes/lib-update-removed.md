+++
kind = "error"
cli = ["kix lib update"]
id = "K6054"
+++
`kix lib update` is removed, and stops with `[K6054]`. Run `kix upgrade --to <version>`, such as `kix upgrade --to 0.10.0`. It changes the tag of the Kix library input in `flake.nix` and locks it. A mirror or a fork pins like any other input.
