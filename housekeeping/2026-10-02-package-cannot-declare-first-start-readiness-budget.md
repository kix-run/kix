# 2026-10-02 · `cli/kix/src/cluster/readiness.rs` · A package cannot declare that its first start takes longer than five minutes.

`kix deploy --timeout` raises the idle budget, but `HARD_CEILING` (five
minutes) caps every readiness wait whatever the flag says. A healthy first
start that pulls a large image, waits for a StackGres bootstrap Job, and runs
schema migrations (`kix/packages/metabase`, `kix/packages/n8n`) can pass five
minutes and is reported as `TimedOut`. The package states a 30-minute startup
budget in its probes and `progressDeadlineSeconds`, and the CLI does not read it.

- Hit again 2026-10-02 on kind (`clusters/test-monitoring-netpol.nix` with a one-instance stackgres-cluster): `SGCluster/pg` failed with "hard ceiling 300s exceeded" on a node with no images cached, though `--timeout 35m` was set.
- Hit again 2026-11-24 by `kix/packages/experimental/nats`: upstream's startup probe allows 15 minutes for `/healthz`, which in a cluster waits for the JetStream metadata leader and stream catch-up, and a roll of many servers can pass five minutes; the header's Limits says so.
