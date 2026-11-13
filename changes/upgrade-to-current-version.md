+++
kind = "added"
+++
`kix upgrade --to <version>` with the version the project is on makes `kix.toml`, `flake.nix`, and `flake.lock` agree on that version. It builds nothing and does not fetch the release index. With `--dry-run`, it checks the Kix library and changes nothing. This applies only when the project's Kix library is on the same minor as that version. A library on an older minor, such as the Kix library 0.9.2 with `kix = "0.10.0"` in `kix.toml`, gets the full upgrade from 0.9.2, with its builds and release notes. `--to` also accepts a prerelease named in full, such as `--to 0.11.0-rc.1`. Error messages that said to run `kix lib update` now name the `kix upgrade --to` command with the version filled in.
