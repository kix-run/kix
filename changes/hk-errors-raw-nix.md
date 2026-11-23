+++
kind = "fixed"
library = ["kix.expose", "kix.mkImport"]
+++
Two mistakes now stop the build with a Kix error that names the cause, where
Nix used to report a missing attribute. `kix.expose` names the instance when
the dependency wired as `ingressNginx` publishes no `out.ingressClassName`.
`kix.mkImport { from }` names the import and the scope builder, such as
`scope.mkSecret` or `scope.mkCRDRef`, when the package's build uses one that
an import does not offer. A package built for an import can now also call
`scope.fail`.
