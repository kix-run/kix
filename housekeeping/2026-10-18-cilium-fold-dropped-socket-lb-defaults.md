# 2026-10-18 · `kix/packages/cilium` · The cilium package lost `socketLB.hostNamespaceOnly` and `bpf.lbExternalClusterIP` in 131335f6.

The old package set both. Without `hostNamespaceOnly`, k3s servicelb (klipper) stops forwarding its HostPort to the NodePort, so a LoadBalancer Service is unreachable on any node address but the one Cilium serves directly. On ludo the gateway went dark on the tailscale IP; `ludo/cluster.nix` now sets both again. Any k3s cluster with servicelb and the cilium package is likely affected.
