# 2026-11-27 · `cli/kix/src/cluster/activation/features.rs` · An operator from before the features annotation, installed after a newer one, is not refused.

The operator refusal (`driven_by_older_operator`) reads `kix.run/operator-features` on the Activation CRD. A newer operator writes `requests,head-lock,revisions` there on startup. An operator from Kix 0.9 or earlier writes nothing and does not clear it, so after a downgrade the CRD still lists `revisions`, and the CLI hands work to an operator that writes the retired annotations back onto every object it applies.
