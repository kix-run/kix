+++
kind = "fixed"
library = ["kix.expose", "kix.mkImport"]
+++
`kix.expose` and `kix.mkImport` now report clear Kix errors instead of bare
missing-attribute messages. When an instance's `ingressNginx` dependency has no
`out.ingressClassName`, `kix.expose` now names the instance and dependency and
shows how to set the class name. When a package passed to `kix.mkImport` via
`from` uses an unsupported `scope` attribute (such as `scope.mkSecret`,
`scope.mkCRDRef`, or `scope.helm`), Kix now names the import instance and
attribute and shows how to set `out` directly. Packages evaluated through
`from` in `kix.mkImport` can now also call `scope.fail`, which reports the
error on the import instance.
