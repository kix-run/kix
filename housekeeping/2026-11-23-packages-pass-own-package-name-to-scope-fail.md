# 2026-11-23 · `kix/packages/` · About 70 package files still pass `package = "<name>"` to `scope.fail`, although `scope.fail` now fills in the package id.

`grep -rn 'package = "' kix/packages` lists about 230 such fields. They
are redundant, and for an experimental package they are wrong: the id is
`experimental/<name>`, and the hand-written field wins over it. Several
packages, such as spegel, cilium, and rabbitmq-cluster, also build warning
and error text from their own `who` prefix instead of the record fields.
