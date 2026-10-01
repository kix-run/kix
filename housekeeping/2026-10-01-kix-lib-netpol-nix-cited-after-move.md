# 2026-10-01 · `kix/lib/plugins/netpol/` · Code and docs still cite `kix/lib/netpol.nix`, which no longer exists.

Network policy derivation lives in `kix/lib/plugins/netpol/`, but a reader who follows the old path finds nothing.
The stale path appears in `cli/kix-cli/src/commands/compliance/audit.rs` (a compliance-audit narrative that users read), `ludo/cluster-kind.nix`, `ludo/cluster.nix`, `ROADMAP.md` (twice), `guide/03-advanced.md`, and `kix/packages/cilium-external/default.nix`.
Several open `v2_discussions/` docs cite it too.
Find them with `git grep -n "lib/netpol\.nix"`.
