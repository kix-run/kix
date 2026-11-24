# 2026-10-03 · `cli/kix/src/plan/server.rs` · `kix plan` lists an existing object as added when its package is new in the build.

`entry()` returns no entry for a package in `packages.added`, so `Overlay::apply`
ignores the dry-run answer for each of its objects, live object included. When
a new package adopts a Deployment that Helm or kubectl made, the plan shows
`+ added` with no field changes and no drift, while the deploy patches the
existing object. Ownership conflicts on it are still reported.
- Hit again 2026-11-24 while taking over Flux-made Deployments: `kix plan` showed `+ web 1.0.0 (3 resources)` and did not show the pod template change that restarted the pods.
