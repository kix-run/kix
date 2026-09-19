# 2026-09-19 · `cli/kix-cli/src/commands/deploy.rs` · A deploy applies `DoNotSchedule` spread constraints on a label no node carries, and the first sign is a stalled rollout ten minutes later.

The derived constraints name `cluster.topology.zoneKey`; a node without
that label is not a domain and cannot host the pod, so on a hand-labelled
cluster every replica stays Pending. Nix cannot see the nodes, and the
CLI never lists them today (`fetch.rs` sweeps managed resources only).
The watchdog then reports "no progress: waiting on Deployment/x
(readiness)", which names neither the label nor the cause. One
`GET /api/v1/nodes` before apply, checked against the distinct
`topologyKey` values in the plan, would give a warning that names the
key and the count of nodes lacking it; a 403 on the list should skip the
check, as the sweep already does for forbidden kinds.
