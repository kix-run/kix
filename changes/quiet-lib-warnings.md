+++
kind = "fixed"
+++
`kix check`, `kix build`, `kix plan`, and `kix deploy` now show the warning that a cluster has no DNS instance, once for the cluster. Before, Kix raised this warning for each instance and did not show it when the build succeeded. The first deploy after upgrading updates the `Activation` object of a cluster that has this warning, because the build index it points to includes the warning list. Workloads and other resources do not change. When an evaluation fails, the full error that `-v` shows no longer includes the Kix library's warnings and scorecard findings.
