# 2026-10-02 · `cli/kix/src/cluster/readiness.rs` · A package cannot declare that its first start takes longer than five minutes.

`kix deploy --timeout` raises the idle budget, but `HARD_CEILING` (five
minutes) caps every readiness wait whatever the flag says. A healthy first
start that pulls a large image, waits for a StackGres bootstrap Job, and runs
schema migrations (`kix/packages/metabase`, `kix/packages/n8n`) can pass five
minutes and is reported as `TimedOut`. The package states a 30-minute startup
budget in its probes and `progressDeadlineSeconds`, and the CLI does not read it.
