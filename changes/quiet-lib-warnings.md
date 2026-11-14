+++
kind = "fixed"
+++
`kix check` now lists the warning that a cluster has no DNS instance, once for the cluster. Before, Kix raised this warning for each instance and did not show it when the build succeeded. When an evaluation fails, the full error that `-v` shows no longer includes the Kix library's warnings and scorecard findings.
