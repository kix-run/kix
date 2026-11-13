+++
kind = "changed"
cli = ["kix upgrade --to"]
+++
`kix upgrade` reads the version a project is on from `flake.lock`, and pins a version by changing the tag of the `kix` input in `flake.nix` and locking. It no longer writes `kix.toml`. `kix upgrade --to <version>` with the version the project is on prints that there is nothing to upgrade, and changes no files. For a project whose `flake.lock` pins no version, such as one with no lock or an input without a tag, `kix upgrade --to <version>` adds the tag to the input's url, writes `flake.lock`, and builds nothing.
