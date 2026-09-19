# 2026-09-19 · `kix/packages/descheduler` · The package renders its Deployment with `replicas = 0`, so it is off unless a cluster overrides it, and no cluster does.

The literal is in the wrapper's chart values. Nothing in the tree uses the
package, so this has never mattered, but the availability level (doc 145)
could not be mapped onto it without turning an eviction controller on by
default, and once it is wired into a cluster at `node` or above the
shortfall warning will name its root Deployment every build. Either the
package should be enabled with a mapped replica count and a deliberate
policy, or removed.
