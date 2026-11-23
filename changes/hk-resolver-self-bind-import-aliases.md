+++
kind = "changed"
library = ["kix.mkImport"]
+++
An import made with `kix.mkImport { from = <package>; }` now answers the package's default aliases, like a managed instance of that package does. For example, an import made from the `valkey` package answers `redis` whatever its instance name is. Set `aliases` on the import instance to replace the default aliases.
