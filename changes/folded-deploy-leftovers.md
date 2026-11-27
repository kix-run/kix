+++
kind = "fixed"
+++
After a failed deploy or a `kix deploy --only` run, `kix plan` and `kix deploy` no longer treat uncreated resources from that unfinished build as orphans. Previously, Kix reported resources that were never applied as orphans, tried to delete them under `--prune`, and recorded the unfinished build under `status.orphansKeptFrom` even when it left nothing on the cluster. Kix now counts a resource from an unfinished deploy as present only when the live object's `kix.run/identity-hash` matches the hash recorded for it in that deployment's revision. In addition, `kix plan` lists fields modified by an unfinished deploy under `earlier_deploys` (attributed to that deployment record) rather than under `Drift`.
