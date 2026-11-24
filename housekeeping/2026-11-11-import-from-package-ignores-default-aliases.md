# 2026-11-11 · `kix/lib/eval/import.nix` · A `kix.mkImport { from = <package>; }` does not answer the package's `meta.defaultAliases`.

An import built from the `valkey` package is found only by its instance name,
although the package answers the alias `redis`. When the Redis dependency was
renamed from `valkey` to `redis`, every such import had to be renamed or given
`aliases = [ "redis" ]`, while a managed `valkey` instance kept working. See
`importedValkey` in `kix/lib/tests/units/n8n.nix`.

A fix tried on 2026-11-23 copied `meta.defaultAliases` from `from` into the
import's `meta`, and was taken out because the same cluster definition then
builds differently with no error. An optional dependency that was unbound
binds the import. A required dependency that Kix filled from
`availablePackages` binds the import, and the managed instance leaves the
build, because `kix/lib/eval/auto.nix` reads the same aliases. And
`meta.conflictsWith` counts the import as a second instance through
`byDefaultAlias` (`kix/lib/meta.nix`), even with `aliases = [ ]`, with an
error that has no change id.

Decision required from Adam: whether an import built from a package should
answer its default aliases (a `silent` breaking record), and whether an
import should count for that package's `meta.conflictsWith`.
