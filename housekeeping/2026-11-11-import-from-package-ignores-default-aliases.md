# 2026-11-11 · `kix/lib/eval/import.nix` · A `kix.mkImport { from = <package>; }` does not answer the package's `meta.defaultAliases`.

An import built from the `valkey` package is found only by its instance name,
although the package answers the alias `redis`. When the Redis dependency was
renamed from `valkey` to `redis`, every such import had to be renamed or given
`aliases = [ "redis" ]`, while a managed `valkey` instance kept working. See
`importedValkey` in `kix/lib/tests/units/n8n.nix`.
