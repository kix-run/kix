+++
kind = "note"
+++
Run `kix deploy --reconcile` once after upgrading. It re-applies every resource without changing any values, so Kix takes ownership of existing Secret keys under `data`. Without this step, a normal deploy skips unchanged Secrets, leaving Secrets deployed by an earlier version of Kix under their old field ownership until Kix writes them again. If that first write removes a key, the key stays on the cluster. Secret keys removed from the build before upgrading also stay on the cluster; delete them with `kubectl` if you want them gone. If you downgrade to an earlier version of Kix, `kix plan --read-only` shows the SOPS keys of Secrets written under `data` as removed until that version deploys them again.
