# 2026-11-21 · `cli/kix-cli` · Kix prints Nix's own error when it runs in a folder with no `flake.nix`.

`kix list clusters` in a repository root whose projects sit in subfolders fails with "path ... does not contain a 'flake.nix', searching up" and "is not part of a flake", under the full `nix eval` command line. The message does not say that Kix found no project here, and does not name `--flake`. Seen with Kix 0.10.0-rc.4. A repository with a project for each environment makes this the first thing a new user sees.
