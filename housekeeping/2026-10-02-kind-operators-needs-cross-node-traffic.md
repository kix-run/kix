# 2026-10-02 · `scripts/kind-operators.sh` · On a NixOS host with the reverse-path filter on, the three-zone kindnet run cannot work at all.

The script header says only the infisical connection check needs cross-node
pod traffic. On this host the filter also drops replies from worker pods to
the control-plane node, so the API server cannot reach any webhook or
aggregated API served from a worker (kubevirt, cdi, mayastor). The W6 K4 run
measured both: pod-to-pod across nodes and control-plane-to-worker-pod time
out under kindnet. With `disableDefaultCNI: true` and Cilium in VXLAN tunnel
mode (`cilium install`, no Kix policy), the same deploy passes every check
without a host change. The script could create its cluster that way, or the
header could say that the host rule is required.
