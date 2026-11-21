+++
kind = "added"
state = true
+++
Existing projects need no changes. To keep clusters in one project on different versions of Kix (for example, to upgrade staging before production), add another Kix library input to `flake.nix` (such as `inputs.kix-stable.url`), list every cluster under an input in the `[versions]` table of `kix.toml` (such as `kix = ["staging"]` and `kix-stable = ["prod"]`), and lock the new input with `kix upgrade <input>`. The `kix` input must pin the newest version of Kix in the project, and Kix runs and builds each cluster with the version its input pins in `flake.lock`. Older versions of Kix in `[versions]` ignore unknown `kix.toml` settings and `mkFlake` arguments, while the version on `kix` checks them all. When `[versions]` is set, `kix list clusters` shows each cluster's version and input, `kix doctor` checks each input, and deploy receipts record the input name in `builder.kixInput`.
