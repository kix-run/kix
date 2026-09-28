# 2026-09-27 · `docs/nix/captures.nix` · Live capture groups see Kix clusters left behind by earlier groups.

The live driver shares one kind cluster across groups, so a Kix cluster one
group deploys stays in place for every group after it until the next
`resetCluster`. `kix diff`, `kix status` and `kix snapshot save` read only the
named Kix cluster, but print `Skipped N objects that belong to Kix cluster X.`
for each other one, so those leftovers still appear in later captures:
`tutorials/04-from-scratch/diff-clean.json` and `status.json` name
`02-hello-world`. Which groups a sidecar depends on is visible only by running
the full sequence.
