+++
kind = "added"
library = ["out.contentHash"]
+++
Every resource now has `out.contentHash`, a hash of its own content. Use it in a pod template's `checksum/<name>` annotation so pods restart when a ConfigMap or Secret they read changes. It stays the same when something the resource depends on changes, or when Kix adds one of its own `kix.run/*` annotations. For a Secret that Kix fills from a SOPS file, it changes when the encrypted file changes. Reading it makes the workload depend on the resource, as reading `out.identityHash` does. Change `checksum/*` annotations in your own packages from `out.identityHash` to `out.contentHash`.
