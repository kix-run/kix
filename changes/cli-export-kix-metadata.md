+++
kind = "error"
cli = ["kix export --for"]
id = "K6794"
+++
`kix export` no longer takes `--for`. Without flags it writes plain Kubernetes YAML, as `--for exit` did. `--with-kix-metadata` keeps Kix's `kix.run/*` annotations and its own records, as `--for audit` did. `kix export --for` fails with an error that names `--with-kix-metadata`.
