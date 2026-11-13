+++
kind = "added"
+++
`kix upgrade --to <version>` with the version the project is on makes `kix.toml`, `flake.nix`, and `flake.lock` agree on that version. It builds nothing and does not fetch the release index. With `--dry-run`, it checks the Kix library and changes nothing. `--to` also accepts a prerelease named in full, such as `--to 0.11.0-rc.1`. Error messages that said to run `kix lib update` now name the `kix upgrade --to` command with the version filled in.
