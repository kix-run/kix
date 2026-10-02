# 2026-10-02 · `cli/kix-cli/src/commands/deploy.rs` · The deploy plan built from live objects still shows what the server filled in.

When the previous activation's store path is gone, `reconstruct_old_from_live` reads the old side through `fetch::kix_owned_manifests`. `kix diff` now uses `fetch::kix_owned_manifests_against`, which compares an object unchanged since its apply as its build manifest. The deploy plan does not, so a webhook default such as the StackGres extension `publisher` can still show there as a change the deploy will make.
