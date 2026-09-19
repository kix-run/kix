# 2026-09-19 · `clusters/flake.nix` · The flake registers `satchel-dev` and `satchel-prod` from `./satchel/`, and that directory is not in the tree.

`nix build ./clusters#cluster-satchel-dev` fails with "path
clusters/satchel/dev.nix does not exist", on main as well as on every
branch, so whatever `satchel/` was (a private cluster kept out of git, or
a directory that never landed) the two entries are dead and any script
that loops over the flake's clusters trips on them. Either commit the
files, gitignore-and-guard the entries, or remove them.
