+++
kind = "fixed"
+++
`kix build`, `kix check`, `kix graph`, `kix list`, and `kix compliance audit` returned the result from before an edit when the edited file was outside the flake directory, such as a package in a Kix library that `flake.nix` names with `path:../kix`, or was not a `.nix`, `.yaml`, `.yml`, or `.json` file, such as a script a package reads. Only `--no-cache` showed the change. The eval cache now uses the fingerprint Nix gives the project, which covers every file an evaluation reads, so these commands evaluate again after any such edit. A command that reads the cache now runs `nix flake metadata` once, which takes about a tenth of a second.
