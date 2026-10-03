# 2026-10-03 · `kix/packages/cnpg-operator` · A CNPG Cluster can report Ready from the previous spec right after a change.

Declared readiness now waits for `observedGeneration` to catch up, but CNPG
writes no `observedGeneration` on the Cluster's `Ready` condition or in its
status. After a spec change, `kix apply` can treat a Cluster as ready before
the operator has reconciled it, so consumers roll against the old state. The
fix needs a different signal, for example `status.phase` together with
`status.currentPrimary`, or an upstream change.
