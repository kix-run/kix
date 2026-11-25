# 2026-11-25 · `kix/lib/flavors/gke-autopilot.nix` · The flavor leaves `criticalPriorityNamespaces` unset, so Kix does not check critical PriorityClasses on Autopilot.

GKE Standard refuses pods with `system-node-critical` or `system-cluster-critical` outside `kube-system`, and the `gke` flavor declares it. Autopilot also refuses all workloads in `kube-system`, so these classes may work in no namespace that a user can deploy to. Nobody has tested it. Until someone does, a package such as `experimental/coredns` builds on `gke-autopilot` and its deploy can time out.
