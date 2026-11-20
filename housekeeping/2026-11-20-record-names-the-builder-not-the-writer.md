# 2026-11-20 · `cli/kix/src/cluster/activation/record.rs` · An Activation record names the Kix that built it, which is not always the Kix that last wrote the cluster.

`Record::deployed_with` reads the receipt's `deployer.kixVersion` or `builder.kixVersion`. A direct rollback writes no receipt, so after Kix 0.11 rolls back to a build that 0.10 made, the Active record says 0.10, and the older-Kix check and the required stops (`cli/kix/src/cluster/stops.rs`) both see 0.10. With `--operator`, the receipt names the CLI's Kix, not the operator's, so a 0.10 CLI behind a 0.11 operator records 0.10.

This is a missing concept: the cluster has no record of which Kix last wrote it. A fix is one annotation, such as `kix.run/written-by`, that whichever program writes a deploy or rollback (the CLI's `finalize_deploy` and the operator) sets to its own version, and that `stops::check` reads in place of the receipt. Records written before it fall back to the receipt.
