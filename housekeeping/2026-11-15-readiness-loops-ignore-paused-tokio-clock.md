# 2026-11-15 · `cli/kix/src/cluster/readiness/` · The readiness loops measure time with `std::time::Instant`, so a paused tokio clock does not move them.

`wait_for_ready` and `wait_for_import_target` sleep with `tokio::time::sleep` but compare elapsed time with `std::time::Instant`. In a `#[tokio::test(start_paused = true)]` test the sleeps return at once and the loop spins against the fake apiserver in real time until the timeout. Tests must pass a timeout of about a second to stay fast (see `discovery_waits` in `readiness/tests.rs`), and none can test a timeout of realistic length.
