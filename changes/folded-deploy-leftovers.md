+++
kind = "fixed"
+++
After a failed deploy or a `kix deploy --only` run, `kix plan` and `kix deploy` no longer treat resources from that build that were never applied to the cluster as orphaned resources. Previously, Kix reported those uncreated resources as orphans, tried to delete them under `--prune`, and recorded the build under `status.orphansKeptFrom` even when it left nothing on the cluster. Kix now counts a resource from an unfinished deploy as present on the cluster only when the live object carries the build hash that deployment record gives it. In addition, fields written by an unfinished deploy now appear under `earlier_deploys` in `kix plan` attributed to that deployment record instead of appearing as cluster drift.
