# 2026-11-23 · `kix/lib/flavors/{gke-autopilot,openshift}.nix` · The `platform-dns` import marker sits in a namespace other than the DNS Service, so `kix deploy` waits for a Service that is not there.

`kix deploy` looks for an imported resource in the namespace of the import's PackageInstance marker (`cli/kix/src/cluster/readiness/imports.rs`). On GKE Autopilot the marker is in `gke-managed` and the Service is `kube-system/kube-dns`. On OpenShift the marker is in `kube-system` and the Service is `openshift-dns/dns-default`. Once a workload activates `platform-dns` on either flavour, the deploy waits for a Service that does not exist in the marker's namespace. An import has no way to name the namespace of the object it stands for.

Ten other flavours write `kube-system` twice, once where they place the instance and once for the helper in `kix/lib/flavors/platform-dns.nix`. Also, `kix.mkImport { kind = "Service"; }` does not derive `out.fqdn`, so every Service import outside the built-in flavours writes the address by hand.

Decision required from Adam: how an import names an object in another namespace. Options:
1. Give `kix.mkImport` a target namespace, which the marker carries and the deploy reads. This means a new argument, a new annotation, and a change to the rule in `imports.rs` that keeps imports in their own namespace.
2. Move the instance into the Service's namespace. This works for OpenShift, but Kix then writes into a namespace the platform owns, and the instance's name changes for users. GKE Autopilot refuses user objects in `kube-system`, so it does not work there.
3. Leave it. No package requires `dns` today, so the deploy check never runs.

Decision required from Adam: whether `kix.mkImport` derives `out.fqdn` for a Service from its name and namespace. Yes makes `platform-dns.nix` unnecessary, depends on option 1, and helps every Service import. No keeps the helper for the built-in flavours only.
