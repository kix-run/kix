+++
kind = "error"
cli = ["kix gc --include unstamped"]
id = "K5538"
+++
`kix gc --full-scan --include unstamped` is removed. Kix now decides that an object is its own from the field managers Kubernetes records on it, not from its `kix.run/identity-hash` annotation, so every object Kix wrote counts as Kix's. An object Kix wrote that no deployment record names is unattributed: use `kix gc --full-scan --include unattributed` to delete such objects. `--include unstamped` fails with an error that names `--include unattributed`.
