+++
kind = "added"
state = true
+++
`PackageInstance` resources for built-in Kix packages now record the package ID in `spec.package`: `<name>` for stable packages (such as `harbor`) and `experimental/<name>` for experimental packages (such as `experimental/coredns`). Kix release notes use the same IDs, so tools inspecting a cluster can match running instances to the notes that affect them. Built-in packages also expose this ID as `.id`, such as `packages.harbor.id` or `packages.experimental.coredns.id`. Kix omits `spec.package` for imports, custom packages, and wrapper functions around built-in packages.
