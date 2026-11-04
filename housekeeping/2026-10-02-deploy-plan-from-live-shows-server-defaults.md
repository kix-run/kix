# 2026-10-02 · `cli/kix/src/plan/baseline.rs` · The deploy plan built from live objects still shows what the server filled in.

When the previous activation's store path is gone, `Baseline::of_cluster` (`of_live`) reads the old side through `owned_view::kix_owned_manifests`. `kix diff` now uses `owned_view::kix_owned_manifests_against`, which compares an object unchanged since its apply as its build manifest. The deploy plan does not, so a webhook default such as the StackGres extension `publisher` can still show there as a change the deploy will make.

The same applies to a Secret. The plain view hides every Secret value, so the plan shows each literal `data` or `stringData` value as changed. It shows no live value.
- Hit again 2026-11-04 while reviewing the live-cluster diff issues: `of_live` still calls `kix_owned_manifests`, not `_against` (`baseline.rs:893`).
