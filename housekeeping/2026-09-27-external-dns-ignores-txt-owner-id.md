# 2026-09-27 · `kix/packages/external-dns` · The `txtOwnerId` option has no effect on the Deployment.

`kix/packages/external-dns/default.nix` computes `ownerId` from
`config.txtOwnerId`, falling back to the instance name, but never adds
`--txt-owner-id` to `args`. Every instance therefore runs with the
external-dns default owner id, so two clusters or instances writing the
same DNS zone can take over each other's records. No cluster evaluates
this package, so a fix cannot be checked against a fingerprint. deadnix
reports `ownerId` as unused until this is fixed.

Passing the flag is not a one-line fix: a running external-dns that
starts with a new owner id stops recognising the TXT records it wrote
under the default id, so the change needs a migration note or a
default that keeps the old id.
