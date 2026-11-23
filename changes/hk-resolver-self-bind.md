+++
kind = "error"
id = "K3646"
+++
Kix now stops with an error when `instances.<namespace>.<name>.deps` has a key that the instance's package does not take. Before, Kix ignored the key, so a misspelt dependency name built without a warning and the dependency was resolved automatically instead. The error names the key and lists the dependencies the package takes. Rename the key to one of them, or remove it. A `deps` key on a `kix.mkImport` instance is refused too, because an import takes no dependencies. To order an import after another instance, use `extraDeps`. When a package has renamed a dependency, the old key fails with an error that gives the new name.
