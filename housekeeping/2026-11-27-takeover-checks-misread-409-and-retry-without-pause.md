# 2026-11-27 · `cli/kix/src/cluster/apply/ssa.rs` · The checks before a forced apply sort the API server's refusals into "try again" and "stop" too roughly.

- `WriteError::CheckRefused` (`migration_write.rs`) always says to run the deploy again, also for a 422 or an admission webhook that denies the dry run, which fail the same way next time. The apply classifies these errors (`classify_apply_error`), and this check does not.
- A 409 from an admission webhook names no field manager, so `taken_in` reads it as `Takes::Moved`. Kix asks five times and then says another writer kept modifying the object. Reading the status reason (`Conflict` with no causes) would tell the two apart.
- `take_back` and `planner::ask` ask up to `TAKEOVER_ATTEMPTS` times with no pause. An object under steady writes ends in `ApplyError::KeepsChanging`, or in no answer at plan time.
