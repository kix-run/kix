+++
kind = "added"
state = true
+++
One project can now hold clusters on different versions of Kix, so you can upgrade staging before production. Add a second Kix input to `flake.nix`, such as `inputs.kix-stable.url`, and a `[versions]` table to `kix.toml` that lists the clusters on each input, such as `kix = ["staging"]` and `kix-stable = ["prod"]`. Kix runs each cluster with the version its input pins. The input `kix` must pin the newest version in the project, and the table must list every cluster. A version of Kix that is older than the one `kix` pins skips the `kix.toml` settings and `mkFlake` arguments it does not know. A project with no `[versions]` table works as before. `kix list clusters` shows each cluster's version, `kix doctor` lists each input, and the deploy receipt records the input as `builder.kixInput`.
