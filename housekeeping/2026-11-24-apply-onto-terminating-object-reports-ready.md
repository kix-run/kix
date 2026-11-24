# 2026-11-24 · `cli/kix/src/cluster/apply/ssa.rs` · `kix deploy` applies onto an object that is being deleted, and a ConfigMap or Secret then reads as ready.

Readiness now fails at once for an object with a `deletionTimestamp`, so a
Deployment or custom resource of the build that is being deleted fails the
deploy. A kind Kix counts as ready once it exists (ConfigMap, Secret,
Service, RBAC objects) skips that check: the apply succeeds, the deploy
reports it ready, and the object disappears when its finalizers clear. The
fix is to wait for the object to go and then create it, with the plan saying
so (doc 178 section 7). It was built and then moved out of the first pull
request, because the plan output and the stateful-replacement question need
their own review.
