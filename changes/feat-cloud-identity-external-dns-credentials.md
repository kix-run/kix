+++
kind = "error"
packages = ["experimental/external-dns"]
id = "K1798"
+++
In `external-dns`, set either `cloudIdentity` (for the matching cloud) or `deps.providerCredentials` on every instance whose `provider` is `aws`, `aws-sd`, `google`, `azure`, `azure-dns`, or `azure-private-dns`. Evaluation now fails when neither or both are set, including on instances that previously omitted `deps.providerCredentials` to use `serviceAccountAnnotations` or the node's own cloud role.
