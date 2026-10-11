# 2026-10-11 · `docs/.../install-and-run-the-kix-cli.mdx` · The install guide tells readers to install from a repository they cannot read.

The page says to run `nix profile install github:kix-run/kixpkgs#kix` and calls it "the public `kixpkgs` flake", but kix-run/kixpkgs is private. The command fails for anyone outside the organisation. Public binaries are now at https://github.com/kix-run/kix-releases.
