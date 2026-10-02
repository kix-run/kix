# 2026-10-02 · `cli/kix/src/cluster/readiness.rs` · A declared `{ path; equals; }` readiness rule passes on a stale status right after an apply.

`check_readiness` compares the value at `path` and never looks at
`metadata.generation` or `status.observedGeneration`, unlike the built-in
workload checks. An AutoscalingRunnerSet (`kix/packages/arc`) that was
`Running` stays `Running` until its controller reconciles the new spec and
writes `Pending`, so a deploy that changed its credentials or URL can pass
before the controller has seen the change. The condition form of the rule has
the same gap when the operator does not stamp `observedGeneration` on its
conditions.
