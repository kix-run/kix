# 2026-10-02 · `kix/packages/firezone` · firezone takes its WireGuard private key, admin password and application secrets as plain-text options, so they sit in the cluster file and the Nix store.

`wireguard.privateKey`, `admin.password` and the six `secrets.*` fields are strings that the build writes into `scope.mkSecret`. Packages such as immich and harbor take credentials through secret dependencies instead. The package also pins Firezone 0.7.26; upstream's current releases are the 1.x line, which it does not support. It depends on the whole `postgres` cluster instead of a per-app `database`. Related entries: `2026-09-27-firezone-password-secret-ref-fails-build.md`, `2026-10-01-firezone-external-url-ignores-its-route.md`.

Decision required from Adam: rework firezone (1.x, credentials through secret dependencies) or delete it with its `clusters/test-immich.nix` instances.
