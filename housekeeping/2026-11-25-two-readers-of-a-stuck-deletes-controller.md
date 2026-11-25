# 2026-11-25 · `cli/kix/src/cluster/` · Two functions read the controller of a stuck delete.

`scheduler::read_controller` reads it through `ResourceIo::get_live` for
deploy's prune, recreate, apply, and the plan. `prune_guard::delete_in_order`
reads it through its own `read_live` for `kix gc` and the operator's
teardown. Both end in `readiness::controller_state`, but the timeout and
the error text differ, so the same unreadable controller reads differently
in `kix deploy` and `kix gc`.
