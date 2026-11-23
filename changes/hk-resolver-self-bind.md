+++
kind = "error"
id = "K3646"
+++
Rename or remove any `instances.<namespace>.<name>.deps` entry whose key is not a dependency of that instance's package. On a `kix.mkImport` instance, remove `deps` entries and use `extraDeps` to deploy the import after another instance. Previously, Kix ignored unknown `deps` keys, so a misspelled dependency name built without warning while Kix resolved that dependency automatically. Kix now stops with an error that lists the package's dependencies, or gives the new name when the package renamed that dependency.
