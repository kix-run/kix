+++
kind = "error"
id = "K4476"
+++
A project's version of Kix now comes from `flake.lock`: the release tag of the flake input named `kix`, such as `github:kix-run/kix/v0.10.0`. Kix runs exactly that version, and installs it when needed. Delete the `kix` line from `kix.toml`, because Kix refuses it with `[K4476]`. A project without `flake.lock`, or whose `kix` input has no release tag, stops with a message that says to run `kix upgrade --to <version>`, which adds the tag and writes the lock. A `kix` input on a local folder or a branch, an `--override-input kix`, or a project that holds the Kix library itself is a development library: Kix runs the version you started, prints a note, and compares no versions. The library a project evaluates must now be the running Kix, so Kix stops when `flake.nix` names another tag than the one `flake.lock` pinned when the command started, and says which `kix upgrade --to` to run.
