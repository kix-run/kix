# 2026-11-24 · `kix/lib/vocab/cloud-identity.nix` · An identity for the wrong cloud gives two errors for one mistake.

`cloudIdentity.gcp` on an EKS cluster with external-dns's `aws` provider fails twice: once from `resolve` (the cluster delivers AWS identities) and once from `orSecret` (the provider calls the AWS API). Both errors are true and give the same fix, so a reader sees noise. `resolve` runs in `eval/instance.nix` and `orSecret` in the package's `assertions`, and neither knows the other fired. Seen while capturing the errors for the cloud identity examples.
