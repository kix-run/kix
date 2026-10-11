# 2026-10-11 · `cli/Cargo.toml` · The CLI workspace declares an MIT licence for a closed-source tool.

`[workspace.package]` sets `license = "MIT"`, and `cli/flake-integration.nix` sets `license = lib.licenses.mit` on the `kix` package. CLAUDE.prose.md says the CLI is proprietary. The binaries are now published publicly at kix-run/kix-releases, so the declared licence is no longer only internal. The same block points `repository` at github.com/kixpkgs/kixpkgs, which does not exist.
