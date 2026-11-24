# 2026-11-24 · `kix/packages/experimental/cert-manager`, `cluster-issuer` · cert-manager cannot take a cloud identity in the shape `kix.cloudIdentity.use` expects.

The controller's ServiceAccount, which needs the identity, is built by the cert-manager package. The DNS provider (Route53, Cloud DNS, Azure DNS) and any static key are chosen on a ClusterIssuer, built by the cluster-issuer package, which depends on cert-manager. So the cert-manager instance cannot name the `cloud` that `use` checks, and a Secret in its dependency has no use, because cert-manager reads static keys from the issuer. Until this is built, users bind the identity with `partsOverlays` on `controllerServiceAccount` (and the Azure pod label on `controllerDeployment`), and the pods get no restart stamp.

Decided, not built: `v2_discussions/180_cloud_identity_across_packages.md` (build plan, step 2).
