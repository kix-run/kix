+++
kind = "changed"
+++
`kix plan`, `kix deploy`, `kix rollback`, and the Kix operator now show a clearer error when `sops` cannot get a decryption key for a SOPS file. The error names the file and explains that either no matching key is configured or `sops` could not reach or use the key service. It also shows how to configure the key on your machine or on the Kix operator pod, and links to the operator SOPS documentation. With `--operator`, the operator retries every 30 seconds (up to 10 times by default) before marking the deploy `Failed`.
