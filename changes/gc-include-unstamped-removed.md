+++
kind = "error"
cli = ["kix gc --include unstamped"]
id = "K5538"
+++
Remove `unstamped` from `kix gc --full-scan --include`, or replace it with `unattributed` when deleting Kix-applied objects that no deployment record or `kix/<cluster>` field manager ties to a Kix cluster. `--include unstamped` was removed and now stops with `[K5538]`. Kix now identifies its objects from Kubernetes `metadata.managedFields` entries instead of the retired `kix.run/identity-hash` annotation, so `kix gc --full-scan` checks objects belonging to the named cluster without an `--include` flag.
