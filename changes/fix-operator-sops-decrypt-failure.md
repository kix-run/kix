+++
kind = "changed"
+++
When `sops` finds no key that decrypts a SOPS file, `kix deploy`, `kix plan`, `kix rollback`, and the Kix operator now name the file, say that the process running the deploy has no matching key or cannot reach the key service, and point to the docs. For `kix deploy --operator`, that process is the operator, which needs the key in its own pod. The operator still retries every 30 seconds until it has the key.
