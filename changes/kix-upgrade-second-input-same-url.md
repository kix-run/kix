+++
kind = "fixed"
+++
`kix upgrade` now updates `flake.nix` automatically even when another input points to the same Kix repository and tag. Kix matches each `url` setting to its input and changes only the input being upgraded. If a matching URL in `flake.nix` cannot be tied to an input, `kix upgrade` still stops and asks you to edit the file.
