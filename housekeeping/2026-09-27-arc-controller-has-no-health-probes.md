# 2026-09-27 · `kix/packages/arc` · The ARC controller has no liveness or readiness probe, so `kix deploy` counts it Ready as soon as the process starts.

The manager image pinned at 0.13.1 has no health endpoints. The
`--health-probe-bind-address` flag first ships in gha-runner-scale-set
0.14.2, and the 0.13.1 manager exits with "flag provided but not
defined" when it is passed, which the package did until 2026-09-27.
Getting probes needs a bump to 0.14.2 or later, which means re-vendoring
the CRDs (crd-vendoring skill) and moving arc-runner-set with it. Until
then `reliability.hasProbes` warns twice for arc.
