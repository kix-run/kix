# 2026-11-18 · `cli/kix/src/cluster/readiness/mod.rs` · A deploy stops at 300 s even when `--timeout 20m` allows more.

On `clusters/test-openbao.nix`, the ExternalSecret waits for a value that a person writes by hand (the header's seed command). With `kix deploy openbao --timeout 20m`, the deploy failed at "hard ceiling 300s exceeded" after 5 minutes, so the header's "while the deploy waits" step does not work as written. Seen on kind (`bump-slot-2`) during the OpenBao 2.7.2 bump.
