# 2026-10-02 · `kix/packages/stackgres-database` · Two apps can share one per-app database, and nothing refuses it.

Two `metabase` instances in one namespace with `deps.database` pointing at the
same `stackgres-database` instance evaluate without a warning. At runtime they
share one application schema: each migrates it, and each encrypts stored
credentials with its own key. n8n and immich have the same shape. A role
binding can be exclusive (`kix/lib/eval/hooks.nix`); a `database` dependency
cannot say it needs to be the only consumer.
