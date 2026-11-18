+++
kind = "fixed"
+++
When a cluster has no DNS instance, `kix check`, `kix build`, `kix plan`, and `kix deploy` now warn once per cluster. Before, Kix never showed this warning when the build succeeded, and repeated it for every instance in `-v` failure output. On a cluster without a DNS instance, the first deploy after upgrading updates the `Activation` object because the build now records this warning. Workloads and other resources do not change. When evaluation fails, `-v` no longer includes the Kix library's warnings or scorecard warnings and info findings in the error output.
