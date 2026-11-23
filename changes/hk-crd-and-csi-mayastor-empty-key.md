+++
kind = "fixed"
packages = ["experimental/mayastor"]
+++
`mayastor` now refuses a toleration in `ioEngine.tolerations` or `csiNode.tolerations` whose `key` is an empty string while `operator` is `"Equal"`, as it already refused one with no key. Kubernetes rejects such a toleration, so a cluster that set one built but failed at deploy. The build now stops with a message that names the entry. Set `key`, or set `operator = "Exists"`.
