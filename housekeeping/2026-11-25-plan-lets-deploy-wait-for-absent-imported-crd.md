# 2026-11-25 · `cli/kix/src/cluster/classify.rs` · The plan lets a deploy start that will wait for an imported CRD nothing installs.

When a custom resource's CRD comes only from an import marker (`scope.mkCRDRef`
without `installedBy`) and the cluster does not serve it, the plan lists the
resource as not checked (`crd_installed_outside_kix`) and the deploy starts.
It then waits at the marker until the readiness timeout and fails. The plan
cannot tell an operator in the build from nothing at all, because the marker
manifest does not say whether `installedBy` was set.

Decision required from the maintainers: stamp `installedBy` on the marker so the plan can
refuse a CR whose CRD nothing will install, or keep the warning as it is.
