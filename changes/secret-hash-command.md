+++
kind = "added"
+++
`kix secret hash <file>` prints the `hash` of a SOPS file's values, for the `hash` of a `packages.secret` instance or of `scope.mkSecret`. It decrypts the file as `kix deploy` does and prints only the hash. It never prints the secret values. Run it after you change a SOPS file.
