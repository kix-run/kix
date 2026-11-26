# 2026-11-26 · `cli/kix/src/cluster/scheduler/node.rs` · No plan makes a `TransitionKind::Wait` node any more, but the code that runs one is still there.

Only consumer clusters used `Wait`, to wait for the platform's copy of Kix's own CRDs. The program now installs those CRDs, so `wait_for_platform` in `node.rs`, the `Wait` checks in `scheduler/plan.rs`, and the `wait` value in `cli/kix-cli/schema/deploy-log.schema.json` are dead. The schema's description of `wait` still says it waits for Kix's CRDs on a consumer cluster. Removing the value changes the deploy log's JSON output.
