# 2026-09-19 · `kix/packages/{arc,velero}` · A controller container with no readiness probe is Ready the instant it starts, so `kix deploy` reported both Deployments ready seconds before they crash-looped on missing CRDs.

Kubernetes marks a pod Ready when every container runs and has no
probe, and a Deployment Available after `minReadySeconds` (zero). The
CLI's verdict followed the API and was wrong in practice: the deploy
went on to apply the dependents. Seen on kind with
`clusters/test-operators.nix`. A readiness probe on the controller (both
serve a health endpoint) or a `minReadySeconds` of a few seconds would
make the verdict mean something; a scorecard rule for "workload with no
probe" would find the rest.
