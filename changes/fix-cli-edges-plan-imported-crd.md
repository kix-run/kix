+++
kind = "fixed"
+++
`kix plan` no longer says a custom resource "uses a CustomResourceDefinition created by this deploy" when the build only references that CRD with `scope.mkCRDRef` and the cluster does not serve it. It now says the CRD "is not on the cluster. Kix does not install it, and the deploy waits for something else to install it". In JSON output these objects have the new `not_checked` reason `crd_installed_outside_kix`. The reason `crd_created_by_this_deploy` now appears only when the build contains the CustomResourceDefinition itself.
