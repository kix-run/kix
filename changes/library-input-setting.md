+++
kind = "added"
+++
`library-input` in `kix.toml` names the input in `flake.nix` that holds the Kix library, such as `library-input = "platform-kix"`. Set it when that input is not named `kix` or `kixpkgs`, or when `flake.nix` has inputs with both names. Kix asks for it in that case.
