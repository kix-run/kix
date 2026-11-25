# 2026-11-25 · `cli/kix/src/cluster/readiness/deletion.rs` · After a stuck delete in `kix rollback --prune`, Kix says to run the same command again, which rolls back one deploy further.

`stuck_explanation` gives every CLI prune path the text "Run the same command
again later". For `kix deploy --prune` that is right. For `kix rollback --prune`
the rollback target is now the Active record, so running `kix rollback` again
picks the next older deploy and rolls the cluster back further. `DeletePath`
does not know whether a deploy or a rollback made the delete, so the message
cannot tell them apart. For a rollback, the right advice is `kix gc`.
