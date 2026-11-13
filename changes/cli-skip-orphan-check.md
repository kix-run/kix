+++
kind = "error"
cli = ["--prune-mode"]
id = "K4285"
+++
`kix plan` and `kix deploy` no longer take `--prune-mode`. Use `--skip-orphan-check` in place of `--prune-mode no`, and leave out `--prune-mode default`, which was the default. `--prune` is unchanged, and `--skip-orphan-check` cannot be combined with it. `--prune-mode` fails with an error that names `--skip-orphan-check`.
