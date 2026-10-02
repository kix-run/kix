# 2026-10-01 · `kix/lib/plugins/netpol/derive.nix` · A package's network intents apply to every workload it renders, not only the one that needs them.

`buildWorkloadCnps` adds all of `meta.network.intents` to each workload's policies. In `kix/packages/cert-manager` the webhook's `from = "apiserver"` ingress also lands on the controller, cainjector, and the API-check Job, and the controller's world egress on 443, 80, and 53 also lands on the webhook and cainjector. Each pod is open wider than it needs. An intent could carry the part name of the workload it is for.
- Hit again 2026-10-02 by `kix/packages/ingress-nginx`: the webhook's `from = "apiserver"` on 8443 and the controller's world and all-pods ingress on 80 and 443 also land on the two certgen Jobs, which listen on nothing.
