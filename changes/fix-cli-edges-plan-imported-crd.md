+++
kind = "fixed"
+++
`kix plan` and `kix deploy` no longer report that an unchecked custom resource "uses a CustomResourceDefinition created by this deploy" when the CRD is missing from the cluster and only referenced externally (with `scope.mkCRDRef` or `kix.mkImport`). They now explain that Kix does not create the CRD and that the deploy waits for an operator or external tool to install it. In plan JSON (`kix plan -o json`, saved plan files, and the plan that `kix deploy` checks), `not_checked` records these resources with the new reason `crd_installed_outside_kix`. `crd_created_by_this_deploy` is now reserved for CRDs included in the build.
