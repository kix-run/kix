# 2026-11-11 · `cli/kix/src/cluster/secrets.rs` · After editing a SOPS file, an author has no Kix command that gives the new `mkSecret` `hash`.

A deploy stops with a hash mismatch for the Secret, and Kix deliberately
never prints the hash it computed, because it is a digest of decrypted
secret data. The only way to get the new value is to rebuild the digest by
hand from the algorithm on the SOPS how-to page, which means decrypting the
file in a shell. So the mismatch message can say what to change but not
what to change it to.
