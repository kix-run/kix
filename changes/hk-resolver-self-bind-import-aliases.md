+++
kind = "changed"
library = ["kix.mkImport"]
+++
`kix.mkImport { from = <package>; }` now inherits `<package>`'s default aliases (`meta.defaultAliases`), just like a managed instance of that package. For example, an import with `from = packages.valkey` now matches `redis` dependencies regardless of its instance name. Set `aliases` on the import instance to replace those defaults, or set `aliases = [ ]` to clear them.
