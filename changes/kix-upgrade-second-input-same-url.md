+++
kind = "fixed"
+++
`kix upgrade` no longer stops and asks you to edit `flake.nix` when a second input uses the same url as the `kix` input. It reads which input each url belongs to and changes only that one. It still stops when it cannot tell, such as when the same url appears outside an input.
