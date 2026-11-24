+++
kind = "error"
packages = ["experimental/external-dns"]
id = "K1798"
+++
On every `external-dns` instance with `config.provider` set to `aws`, `aws-sd`, `google`, `azure`, `azure-dns`, or `azure-private-dns`, set `deps.providerCredentials` to a matching cloud identity (`kix.cloudIdentity.aws`, `kix.cloudIdentity.gcp`, or `kix.cloudIdentity.azure`) or to a Secret instance. Evaluation now fails when `deps.providerCredentials` is unset for these providers, including on instances that previously relied on `config.serviceAccountAnnotations` or the node's cloud IAM role.
