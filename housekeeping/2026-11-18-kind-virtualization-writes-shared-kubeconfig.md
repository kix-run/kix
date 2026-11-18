# 2026-11-18 · `scripts/kind-virtualization.sh` · The script cannot run beside other kind clusters without changing the shared kubeconfig.

The script calls `kind create cluster --name "$NAME"` and `kind delete
cluster --name "$NAME"` without `--kubeconfig`, so both change the
current context in `~/.kube/config`. Every kix and kubectl call then
passes `--context kind-$NAME` and reads that same file. An agent that
runs it while other agents use kind clusters on the machine moves their
current context. The cdi upgrade test therefore created its cluster by
hand with `--kubeconfig /tmp/kc-<name>` and ran `kix deploy virtualization`
directly, and so skipped the script's checks (Cilium drops, aggregated
API availability, apply order). The script could take a `KUBECONFIG`
path and pass it to kind.
