# 2026-11-26 · `cli/kix-operator/src/controller.rs` · The operator writes some record phases without holding the deploy lock.

`start_queued` supersedes older Queued records, fails a Queued record that
its checks refuse (`Records::fail_queued`), and counts a failed attempt to
read a build (`after_failed_attempt`) before `run_reconcile` takes the lock.
`requeue`, `start_request`, `finish_request`, and `fail_request` run outside
it too. These writes do not order against a `kix deploy` from a machine, so a
record's phase can still change under a run that holds the lock.
