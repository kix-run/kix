+++
kind = "note"
+++
A Secret that an earlier release of Kix deployed keeps its old field ownership until Kix writes it again, and a deploy writes it only when the build changes it. Until then, a key removed in that first write stays on the cluster. Run `kix deploy --reconcile` once after you upgrade: it writes every object again without changing any value, and Kix then owns every Secret key under `data`. Keys removed from a build before the upgrade stay on the cluster; delete them with `kubectl` if they matter. After a downgrade, `kix plan --read-only` from the earlier Kix shows the SOPS keys of these Secrets as removed until that Kix deploys them again.
