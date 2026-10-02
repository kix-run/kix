# 2026-10-02 · `kix/packages/cilium` · A fresh install with `networkPolicy.enable` drops coredns and local-path-provisioner traffic to the API server for a short while.

Right after Cilium starts, its drop monitor reports `Policy denied` for SYNs
from both coredns pods and `local-path-provisioner` to `172.18.0.4:6443`,
with the destination identity `host` rather than `kube-apiserver`. The pods
retry and recover, and their egress policies (`coredns-egress`,
`local-path-provisioner-egress`) allow the API server. Cilium has probably not
yet given the node IP the `kube-apiserver` identity. The two deploys of the
W6 kind run K7 saw 21 and 25 of these, and K6 counted 21 drops it could not
attribute, so any check that reads `cilium_drop_count_total` after a fresh
deploy sees them.
