# 2026-09-27 · `docs/nix/captures.nix` · Live capture groups see Kix clusters left behind by earlier groups.

The live driver shares one kind cluster across groups, so a Kix cluster one
group deploys stays in place for every group after it until the next
`resetCluster`. Because Kix's cluster-wide listings do not filter by Kix
cluster (see `2026-09-27-managed-sweep-ignores-cluster-label.md`), those
leftovers appear in later captures: `how-to/adoption-stateful-migration`
leaves `how-to-stateful-migration` (Namespace `data`, PVC `media-v1`)
deployed, and without a reset `kix status`, `kix health` and `kix diff`
report it under `how-to-application`. Which groups a sidecar depends on is
visible only by running the full sequence.
