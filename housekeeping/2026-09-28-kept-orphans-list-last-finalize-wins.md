# 2026-09-28 · `cli/kix/src/cluster/ops/kube.rs` · Two deploys planned against the same Active record overwrite each other's `status.orphansKeptFrom`.

Each deploy computes the list from the Active record it read when it planned,
and `KubeOps::finalize` writes it whole. If machines A and B both plan against
record R, and A finalizes first with a list that names a build, B's finalize
supersedes A's record and writes a list computed without A's build. The orphans
A kept are then invisible to `kix deploy --prune` and soft `kix gc`, and only
`kix gc --hard` finds them. Nothing orders or detects the two runs; the
`Deploying` check in `baseline::deploy_in_flight` only drops the failed-record
fold.
