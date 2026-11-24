+++
kind = "error"
id = "K3646"
+++
Rename or remove any `instances.<namespace>.<name>.deps.<key>` entry that does not match a dependency of that instance's package. On a `kix.mkImport` instance, remove `deps` and use `extraDeps` if the import must deploy after another instance. Kix now rejects unknown `deps` keys on every declared instance: the error lists the package's valid dependencies, or gives the new name when the package renamed that dependency. Previously, Kix ignored unknown `deps` keys, so a misspelled key had no effect and built without warning.
