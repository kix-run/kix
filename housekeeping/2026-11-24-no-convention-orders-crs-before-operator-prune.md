# 2026-11-24 · `kix/lib/scope/builders.nix` · Nothing orders an operator's custom resources before the operator on prune unless the package remembers to.

A custom resource built from `out.crds` depends on its CRD, not on the
operator that serves it. When both are pruned, nothing makes the custom
resource's delete come first, so a finalizer only the operator removes can
be left behind. Each operator package has to add `crRequires = [ self.<operator> ]`
by hand; keda does, most packages do not. A default on `scope.mkCRD` (the
package's controller workload) would cover every operator.
