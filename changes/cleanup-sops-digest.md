+++
kind = "error"
packages = ["secret"]
library = ["scope.mkSecret", "kix.contracts.secret"]
id = "K4732"
cli = ["kix secret hash", "AdmissionRefusal.sops_source", "RefusalReason hash_mismatch"]
+++
You no longer write a `hash` for a SOPS file. Kix now records the SHA-256 of the encrypted file itself, in the annotation `kix.run/sops-digest`, and `kix deploy` checks the file against it before decrypting. A `packages.secret` instance or a `scope.mkSecret` call that still sets `hash` fails the build with `[K4732]`: delete the `hash` line. A package that read `out.sops.hash` from a secret reads `out.sops.digest` instead. `kix secret hash` is removed, since there is no hash to compute. The plan document (`-o json`) loses the `hash_mismatch` refusal reason and the `sops_source` field, and its `schema_version` is now `2026-11-13`.
