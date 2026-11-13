+++
kind = "error"
id = "K9179"
+++
Kix reads the Kix library only from the flake input named `kix`. A project whose input is named `kixpkgs` stops with `[K9179]`. Rename the input to `kix` in `flake.nix`, including `inputs.kixpkgs.lib.mkFlake` and any `inputs.kixpkgs.inputs.nixpkgs.follows` line, then run `kix upgrade --to <version>` to lock it.
