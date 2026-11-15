+++
kind = "error"
packages = ["experimental/reflector", "experimental/secret-echo"]
id = "K9332"
+++
The experimental packages `reflector` and `secret-echo` are removed. Nothing used `reflector`, and by default it copied a Secret into every namespace. `secret-echo` was a test fixture that served the credentials it read on an HTTP page. A cluster that names either one fails with an error. Create a Secret in each namespace that reads it, for example with `packages.secret` from a SOPS file or with `packages.experimental.external-secrets`.
