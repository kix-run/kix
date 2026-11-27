+++
kind = "fixed"
+++
After a failed deploy or a `kix deploy --only` run, `kix plan` and `kix deploy` no longer treat uncreated resources from that unfinished build as orphans. Previously, Kix listed resources that were never applied as orphans, tried to delete them under `--prune`, and recorded the unfinished build under `status.orphansKeptFrom` even when it left nothing on the cluster. Kix now counts a resource from an unfinished deploy as present only when the live object carries that deployment's build hash, and `kix plan` lists fields modified by an unfinished deploy under `earlier_deploys` (attributed to that deployment record) rather than under `Drift`.
