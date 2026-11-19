+++
kind = "added"
state = true
library = ["packages"]
+++
`PackageInstance` resources for built-in Kix packages now record the package ID in `spec.package`: `<name>` for stable packages (such as `harbor`) and `experimental/<name>` for experimental packages (such as `experimental/coredns`). Release notes use the same IDs, so tools inspecting a cluster can match running instances to release notes. Built-in packages also expose this ID as `.id`, such as `packages.harbor.id` or `packages.experimental.coredns.id`. Imports, custom packages, and wrapper functions around built-in packages omit `spec.package`. Your first deploy after upgrading updates affected `PackageInstance` resources without restarting any workloads.
