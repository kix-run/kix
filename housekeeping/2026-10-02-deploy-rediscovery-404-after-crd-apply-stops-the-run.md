# 2026-10-02 · `cli/kix/src/cluster/scheduler.rs` · `kix deploy` stops the whole run when API rediscovery after a CRD apply gets a 404.

On a fresh kind cluster, `kix deploy tailscale --flake ./clusters` applied and saw Established for the eight tailscale.com CRDs, then failed with "API rediscovery failed after CRD apply: could not discover the resource types supported by the Kubernetes API: ApiError: \"404 page not found\"" and cancelled the 26 remaining resources. The new group/version was not yet in discovery when the CLI asked; a retry of the rediscovery would likely have passed. Related: `2026-09-27-deploy-discovery-fails-on-one-unavailable-apiservice.md`.

- Hit again 2026-10-02 on a fresh three-node kind run of `kix deploy operators --flake ./clusters` (cluster-operators): the first deploy stopped about 30 s in with the same 404 and cancelled 36 resources; a second deploy finished with 0 failed.
- Hit again 2026-10-02 on a fresh ludo-kind run (kind/w9-ludo attempt 1) right after the ten vendored monitoring.coreos.com CRDs were Established: 97 created, 210 cancelled. The second fresh cluster deployed with 0 failed.
