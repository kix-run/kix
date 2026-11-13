+++
kind = "fixed"
+++
When a SOPS file's values no longer match its `hash`, `kix plan` and `kix deploy` report the problem once for that file and list the Secrets it affects. Before, they printed one "could not decrypt" error for each Secret, including the Secrets that a database package makes from the same file. The report names the instance whose `hash` to change and says to run `kix secret hash`. When every problem is a hash mismatch, `kix deploy` no longer suggests `--on-error continue`. In the plan document, these refusals now have the reason `hash_mismatch` and a `sops_source` field, where before they had the reason `decryption`.
