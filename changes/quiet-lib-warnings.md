+++
kind = "fixed"
+++
`kix check` now lists the warning that a cluster has no DNS instance, once for the cluster. Kix raised this warning before and did not show it when the build succeeded. When an evaluation fails, the full error that `-v` shows no longer includes the library's warnings and scorecard findings.
