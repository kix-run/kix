+++
kind = "fixed"
library = ["kix.expose", "kix.mkImport"]
+++
When an `ingressNginx` dependency does not set `out.ingressClassName`,
`kix.expose` now names the affected `Ingress`, instance, and dependency, and
shows how to set the class name. When a package passed in `from` to
`kix.mkImport` uses an unsupported `scope` field (such as `scope.mkSecret`,
`scope.mkCRDRef`, or `scope.helm`), Kix now names the import instance and that
field, and shows how to set `out` directly. A `from` package in `kix.mkImport`
can now also call `scope.fail` to report an error on the import instance.
Before, all three cases failed with `attribute '...' missing`, without naming
the instance or giving a fix.
