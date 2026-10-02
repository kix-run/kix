# 2026-10-02 · `kix/packages/metabase` · Metabase runs without `MB_SESSION_SECRET_KEY`, so its session keys are unsigned.

Metabase v0.63.19 logs at every start in the W6 kind run K14: "MB_SESSION_SECRET_KEY is not set; session keys are stored without a signature. Anyone with access to the application database can forge a session and impersonate any user." The package wires only `MB_ENCRYPTION_SECRET_KEY` from the `encryptionKey` dependency, and the header does not mention the session key. A user can set it through `env` with a `secretKeyRef`, but nothing points them to it.

Decision required from Adam: read a second key (for example `sessionKey`) from the `encryptionKey` secret, add a separate dependency, or document `env` as the way to set it.
