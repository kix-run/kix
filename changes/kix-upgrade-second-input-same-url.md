+++
kind = "fixed"
+++
`kix upgrade` now updates `flake.nix` automatically even when another input points to the same Kix repository and tag. Kix matches each `url` setting to its input and updates only the input being upgraded. If `flake.nix` has another matching URL and Kix cannot tell which input owns it, `kix upgrade` still stops and asks you to edit `flake.nix` yourself.
