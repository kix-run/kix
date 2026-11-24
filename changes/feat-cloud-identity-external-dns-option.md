+++
kind = "error"
packages = ["experimental/external-dns"]
id = "K0771"
+++
In `external-dns`, replace `config.serviceAccountAnnotations` with `cloudIdentity` on the instance (for example, `cloudIdentity.aws.roleArn`, `cloudIdentity.gcp.serviceAccount`, or `cloudIdentity.azure.clientId`). `serviceAccountAnnotations` was removed and now fails evaluation. Switching to `cloudIdentity` writes the cloud's ServiceAccount annotations (plus pod label `azure.workload.identity/use: "true"` on AKS), adds `kix.run/cloud-identity` to the ServiceAccount and `checksum/cloud-identity` to the pod template, and restarts the pod once on the first deploy.
