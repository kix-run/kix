+++
kind = "error"
packages = ["secret"]
library = ["scope.mkSecret", "kix.contracts.secret"]
id = "K4732"
+++
You no longer write a `hash` for a SOPS file. Kix now records the SHA-256 of the encrypted file itself, in the annotation `kix.run/sops-digest`, and `kix deploy` checks the file against it before decrypting. A `packages.secret` instance or a `scope.mkSecret` call that still sets `hash` fails the build with `[K4732]`: delete the `hash` line.
