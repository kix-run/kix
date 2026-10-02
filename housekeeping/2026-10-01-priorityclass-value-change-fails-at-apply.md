# 2026-10-01 · `cli/kix/src/cluster/scheduler.rs` · Changing an immutable field such as a PriorityClass `value` passes the build and fails at apply.

The apiserver refuses an update to a PriorityClass's `value` or
`preemptionPolicy`. `kix deploy` recreates an object on an immutable
conflict only when it is a pre-authorized orphan (`scheduler.rs:1511`), so
editing `config.value` of a deployed `priority-class` instance fails during
the deploy. Other kinds with immutable fields behave the same. The planner
sees the live and the built object and could refuse the change at plan time.
