# 2026-11-21 · `cli/kix-cli` · `kix list clusters -o json` leaves out each cluster's Kix version.

In a project with a `[versions]` table, `kix list clusters` prints a `KIX`
and an `INPUT` column. The JSON output is a bare list of cluster names
(`ClustersResponse` in `cli/kix-cli/src/commands/list.rs`), so a script or
a CI job cannot read which version a cluster is on.

A list of names has no room for a field. Putting the versions in the JSON
output changes its shape, which is a breaking change, unless another
command or flag carries them.

Found by a review of kix#288 on 21 November 2026.
