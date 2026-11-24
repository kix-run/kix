+++
kind = "error"
packages = ["experimental/external-dns"]
id = "K0771"
+++
On `external-dns` instances, remove `config.serviceAccountAnnotations` and set `deps.providerCredentials` to a cloud identity (`kix.cloudIdentity.aws { roleArn = "..."; }`, `kix.cloudIdentity.gcp { serviceAccount = "..."; }` or `kix.cloudIdentity.gcp { }`, or `kix.cloudIdentity.azure { clientId = "..."; }`), or add custom ServiceAccount annotations with `partsOverlays`. Setting `config.serviceAccountAnnotations` now fails evaluation. Moving to `kix.cloudIdentity` writes the cloud's ServiceAccount annotations (and pod label `azure.workload.identity/use: "true"` on AKS), adds `kix.run/cloud-identity` to the ServiceAccount and `checksum/cloud-identity` to the pod template, and restarts the `external-dns` pod once on the next deploy.
