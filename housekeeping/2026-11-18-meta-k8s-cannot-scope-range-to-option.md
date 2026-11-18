# 2026-11-18 · `kix/lib/meta.nix` · `meta.k8s` cannot give a Kubernetes range that applies only when an option is on.

`otel-collector` runs the contrib `k8s_objects` receiver only with `events.enabled`. Upstream states a Kubernetes range for that receiver alone (`receiver/k8sobjectsreceiver/README.md` at v0.165.0: its e2e versions, 1.34 and 1.35, "represent the officially supported Kubernetes versions for this component") and none for the collector. `meta` is static, so the package can either refuse every cluster outside 1.34 to 1.35, which also refuses gateway-only instances and any cluster running `kube-state-metrics` (1.36 only), or refuse none. It refuses none today.

This pairs with the readiness design now being planned. Both are facts that hold per kind or per component, and `meta` cannot express them.

Decision required from Adam: whether `meta.k8s` may depend on `config`, a package assertion may read `clusterConfig.k8sVersion` for this, or a component-scoped range stays unchecked.
