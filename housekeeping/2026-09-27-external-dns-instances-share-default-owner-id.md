# 2026-09-27 · `kix/packages/external-dns` · Every instance without `txtOwnerId` writes TXT records under the same owner id, `default`.

`txtOwnerId` defaults to null, which omits `--txt-owner-id`, so external-dns
uses its built-in owner id `default`. Two clusters or instances that write the
same DNS zone with the default can take over and delete each other's records.
The default stays because records written so far carry `default`, and a
running install that switches id stops managing its old TXT records. A
per-instance default needs a migration path for those records.
