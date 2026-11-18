# 2026-11-18 · `kix/packages/experimental/firezone` · A Firezone rollout fails when the old and new pods both connect, because the default pool is two connections per node core.

Firezone 0.7 sizes its database pool at two connections per logical core
of the node (`DATABASE_POOL_SIZE`, `config/runtime.exs`). On a 32-core kind
node one pod takes 65 of StackGres's 100 connections. The Deployment uses
`RollingUpdate` with `maxSurge: 25%`, so the new pod starts while the old
one still holds its pool, and the new pod crashes with `too_many_connections`
until the old pod exits. The deploy then fails with CrashLoopBackOff. The
package header says one process owns the WireGuard interface, which argues
for `Recreate`, but nothing in the package sets it. Found while upgrading
0.7.26 to 0.7.36 on `clusters/test-firezone.nix`, which now caps the pool at
10 with `env.DATABASE_POOL_SIZE`. Options for a fix are in the PR that
picks this up, not here.
