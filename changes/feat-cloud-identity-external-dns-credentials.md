+++
kind = "error"
packages = ["experimental/external-dns"]
id = "K1798"
+++
Set `deps.providerCredentials` on every `external-dns` instance whose `config.provider` is `aws`, `aws-sd`, `google`, `azure`, `azure-dns`, or `azure-private-dns`. Pass either a matching cloud identity (`kix.cloudIdentity.aws`, `kix.cloudIdentity.gcp`, or `kix.cloudIdentity.azure`) or a Secret instance. Evaluation now fails when `deps.providerCredentials` is unset for these providers, including on instances that previously relied on `config.serviceAccountAnnotations` or the node's cloud IAM role.
