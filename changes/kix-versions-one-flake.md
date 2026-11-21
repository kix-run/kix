+++
kind = "added"
state = true
+++
You can now keep clusters in one project on different versions of Kix, for example to upgrade staging before production; existing projects without `[versions]` need no changes. To keep a cluster on an older version, add another Kix input to `flake.nix` (such as `inputs.kix-stable.url`) and map every cluster to an input in the `[versions]` table of `kix.toml` (such as `kix = ["staging"]` and `kix-stable = ["prod"]`). The `kix` input must pin the newest release in the project, and Kix runs and builds each cluster with the version its input pins in `flake.lock`. Older Kix versions in `[versions]` ignore `kix.toml` settings and `mkFlake` arguments they do not recognize, while the version on `kix` checks them all. When `[versions]` is set, `kix list clusters` shows each cluster's version and input, `kix doctor` checks each input, and deploy receipts record the input name in `builder.kixInput`.
