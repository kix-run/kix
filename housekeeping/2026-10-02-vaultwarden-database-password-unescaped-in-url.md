# 2026-10-02 · `kix/packages/vaultwarden` · The database password goes into DATABASE_URL unescaped.

Vaultwarden reads its database only from a URL, and the package builds it as `postgresql://$(DB_USERNAME):$(DB_PASSWORD)@host:port/db` from the credentials Secret. A password containing `@`, `/`, `:`, `?`, or `#` breaks the URL, and Vaultwarden fails to connect at start. Nothing checks it: the password comes from a SOPS file at deploy time, so evaluation never sees it. The limit is written in the package header only.
