+++
kind = "error"
packages = ["experimental/reflector", "experimental/secret-echo"]
id = "K9332"
+++
If your cluster uses the `reflector` or `secret-echo` package, remove it from your cluster definition. To replace `reflector` or its `out.reflectSecret` helper, create a Secret in each namespace that needs it. For example, use `packages.secret` with a SOPS file, or sync Secrets with `packages.experimental.external-secret` and `packages.experimental.external-secrets`. Both experimental packages have been removed, and referencing `packages.experimental.reflector` or `packages.experimental.secret-echo` now stops evaluation with an error. The `out.reflectSecret` helper in `reflector` copied a Secret into every namespace by default, and `secret-echo` was a test fixture that served Secret credentials in plain text over HTTP.
