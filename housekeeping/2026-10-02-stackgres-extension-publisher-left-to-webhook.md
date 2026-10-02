# 2026-10-02 · `kix/packages/stackgres-cluster` · The SGCluster leaves each extension's `publisher` for the operator's webhook to fill in.

The webhook adds `publisher: com.ongres` to every entry of `spec.postgres.extensions`. While the SGCluster is unchanged `kix diff` does not show it, but any change to it makes the diff list one `- publisher` line per extension that the deploy will not change.
