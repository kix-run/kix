# 2026-11-24 · `kix/lib/helm.nix` · `kix.helmChart` exposes none of `deps`, `networkDeps`, `extraEdges`, `includeHooks`, or `kubeVersion`.

The inline chart constructor passes only a fixed subset of arguments to `importChart`. A user who starts with `kix.helmChart` and needs network policy to a dependency, an order for a former hook Job, or a `.Capabilities.KubeVersion` that matches the cluster has to rewrite it as a package. The docs now say so in `reference/helm-and-imports.mdx`.
