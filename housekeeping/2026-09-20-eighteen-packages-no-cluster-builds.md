# 2026-09-20 · `kix/packages` · Eighteen of the 64 packages are named by no cluster, so nothing ever evaluates them.

`arc-runner-set`, `caddy`, `cilium-external`, `cilium-rke2`,
`cloudflared`, `descheduler`, `dns-exporter`, `event-logger`,
`external-dns`, `metabase`, `n8n`, `network-policies`, `posthog-proxy`,
`priority-classes`, `prometheus-default-rules`, `smartctl-exporter`,
`stackgres-object-storage` and `stackgres-pgpass-perms-fix` appear in no
file under `clusters/` or `ludo/`. A change to one of them can be parsed
and formatted and nothing more: no builder runs, no validator runs, no
scorecard rule runs, and a `nix build` of every cluster stays green.

Found while removing hand-written PodDisruptionBudgets: caddy's edit was
the only one of the three that no build could confirm. A sweep across
packages — the port-name sweep, the seal conversion, a future rename in
the lib — silently skips a quarter of the tree.

Adding all eighteen to a cluster would be slow to build and would tangle
unrelated packages together. A build target that only evaluates each
package against a stub scope would catch the same class for the price of
an eval.
