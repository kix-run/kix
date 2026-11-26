+++
kind = "error"
state = true
id = "K9557"
+++
Before upgrading, grant every Kubernetes account that changes a cluster (including the Kix operator) `get`, `list`, `create`, and `update` on `activationheads.kix.run`, and grant `get` and `create` on `customresourcedefinitions` to the Kix operator or the account that first runs `kix deploy`, `kix rollback`, `kix gc`, or `kix migrate domain` so Kix can create the `activationheads.kix.run` CRD once. If you use operator mode, upgrade the Kix operator before running `kix deploy --operator` or `kix rollback --operator`. Commands stop before changing anything when these permissions are missing (reporting `[K9557]` when Kix cannot read or create the `activationheads.kix.run` CRD), and `--operator` commands stop with `[K9557]` until the upgraded operator lists `head-lock` in `kix.run/operator-features` on `activations.kix.run`.
