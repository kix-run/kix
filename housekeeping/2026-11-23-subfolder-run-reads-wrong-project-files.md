# 2026-11-23 · `cli/kix-cli` · Kix run from a subfolder of a project evaluates the parent project but reads `kix.toml` and `flake.lock` from the subfolder.

When the `--flake` folder (by default the working folder) has no `flake.nix`, Nix looks for one in the folders above and evaluates that project. Nix stops looking at the first folder that holds `.git`. Kix reads the project's files from the `--flake` folder itself: `kix.toml` (`commands::select_builder`), the `[versions]` table (`kix::versions::choose` in `dispatch::prepare_evaluation`), and `flake.lock` (`select::project_kix`, which then skips choosing a version). So `kix build c` run in `clusters/` uses the default builder and the running Kix, whatever the project sets. A project that sets `builder = "nix"` fails with a builder mismatch that does not mention the folder.

The same gap causes `2026-11-21-no-flake-folder-prints-raw-nix-error`. Kix has no one place that decides where the project is, so it cannot tell a person that it found no project. A check added to `prepare_evaluation` alone would be one more copy of that decision.

Decision required from Adam: choose how Kix finds the project folder.

1. Find the project folder once, the way Nix does (walk up to the first `flake.nix`, stopping at a folder with `.git`), and give that folder to every reader of `kix.toml`, `[versions]`, and `flake.lock`. A run from a subfolder then works fully, and "found no folder" becomes the friendly no-project error. Nothing breaks. It costs a pass over every caller of `commands::project_dir` and `select::project_kix`.
2. Refuse a `--flake` folder that has no `flake.nix` of its own, with an error that names `--flake`. This is the smallest change. It is a breaking change of kind `error`, because a run from a subfolder works today for a project with the default builder and no `[versions]` table.

Option 1 removes the cause and is the recommended one.
