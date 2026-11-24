+++
kind = "error"
packages = ["experimental/external-dns"]
id = "K0771"
+++
Remove `config.serviceAccountAnnotations` from `external-dns` instances. For cloud authentication, set `deps.providerCredentials` to `kix.cloudIdentity.aws`, `kix.cloudIdentity.gcp`, or `kix.cloudIdentity.azure`; for custom ServiceAccount annotations, use `partsOverlays`. Setting `config.serviceAccountAnnotations` now fails evaluation. Switching to `kix.cloudIdentity` writes the cloud's ServiceAccount annotations (plus pod label `azure.workload.identity/use: "true"` on AKS), adds `kix.run/cloud-identity` to the ServiceAccount and `checksum/cloud-identity` to the pod template, and restarts the `external-dns` pod once on the next deploy.
