+++
kind = "error"
packages = ["experimental/external-dns"]
id = "K0734"
+++
If `external-dns` uses `provider = "aws"` or `"aws-sd"` with a Secret in `deps.providerCredentials`, set `config.env.AWS_REGION` (or `AWS_DEFAULT_REGION`) or provide that variable from the Secret. `external-dns` now fails the build when no AWS region is configured. Previously, the build succeeded and the pod exited at startup with "Missing Region", because static access keys in a Secret do not set a region automatically (unlike `kix.cloudIdentity.aws`).
