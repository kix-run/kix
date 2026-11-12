# 2026-11-12 · `packages.secret` · Updating `hash` after changing a SOPS file needs a hand-written shell pipeline.

The hash is SHA-256 over the decrypted `key=value` lines, and Kix refuses to print it. Rotating a database password means computing it with `printf 'password=...\n' | sha256sum | xxd -r -p | base64`, which puts the new password in shell history.
