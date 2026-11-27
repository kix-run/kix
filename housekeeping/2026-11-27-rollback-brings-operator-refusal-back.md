# 2026-11-27 · `cli/kix/src/cluster/activation/features.rs` · A rollback to a record an old operator deployed brings the `[K9557]` refusal back after `--operator-removed`.

`kix deploy --operator-removed` (`features::take_back`) removes `spec.source` only from the current, queued, and deploying records the operator was handed. A later `kix rollback` to an older `Superseded` record that the operator deployed makes it current again with its `spec.source`, so every command that changes the cluster is refused once more, until another `kix deploy --operator-removed`.

Decision required from Adam: keep this (one more flagged deploy, history untouched), or clear `spec.source` on every operator record of the cluster during the take-back (one write per record, and the records lose the trace that they came through the operator).
