# 2026-11-26 · `cli/kix/src/cluster/scheduler/mod.rs` · A deploy whose finalize fails leaves its record `Deploying`, and the next plan then leaves out every `Failed` record.

`DeployError::FinalizeFailed` returns without `abort`, so the record keeps phase `Deploying` after the lock is released. The next plan takes a `Deploying` record as a deploy that may still be running (`FailedBaseline::left_out`), so it does not take in what earlier `Failed` or `Partial` deploys left until someone runs the `kubectl patch` the error prints.
