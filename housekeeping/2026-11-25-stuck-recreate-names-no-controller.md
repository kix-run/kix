# 2026-11-25 · `cli/kix/src/cluster/ops/resources.rs` · A stuck recreate or apply-onto-deleting names no controller.

Only the delete loops that walk a `DeleteOrder` (prune, `kix gc`, the
operator's teardown) read the `controller:` entries of `kix.run/depends-on`
and say whether the controller runs. When the delete before an in-place
recreate, or the wait before applying onto an object being deleted, ends
with `[K2794]`, `Stuck.controllers` stays empty, although the manifest in
hand carries the same entries.
