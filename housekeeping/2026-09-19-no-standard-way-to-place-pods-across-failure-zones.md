# 2026-09-19 · `kix/packages/*` · Every package invents its own pod anti-affinity, and none of them asks the cluster whether it has more than one node.

Fourteen packages hand-roll `podAntiAffinity` or `topologySpreadConstraints`,
each with its own option names and defaults: `enableAntiAffinity` plus
`antiAffinityTopologyKeys` in `kix/packages/ingress-nginx/default.nix:186`, a
local `antiAffinity` function in `victoria-metrics-cluster` and
`victoria-metrics-alert`, inline terms elsewhere. A reader cannot tell from one
package what the house rule is, and a new package has nothing to copy.

The cluster already states the answer and nobody reads it.
`cluster.capabilities.multiNode` (`kix/lib/modules.nix:325`) is set by the kind,
scaleway and ovh flavors and by `ludo/cluster.nix:20`, and no package consults
it. So ludo, a single-node cluster, still renders ingress-nginx pods that ask to
spread across `kubernetes.io/hostname` and `topology.kubernetes.io/zone`. The
terms are `preferred`, so nothing hangs, but the rules are noise the scheduler
weighs for no gain, and a `required` rule in some future package would leave
pods Pending forever with no build-time warning.

The zone half has no source at all.
`cluster.capabilities.availabilityZones` (`kix/lib/modules.nix:335`) is declared
and never set or read, so `topology.kubernetes.io/zone` appears in package
defaults as a guess. This is the failure-zone dependency-injection question: a
package should be able to ask for "spread across failure zones" and have the
cluster decide what a zone is (host, rack, site, cloud AZ), rather than each
package naming a topology key. It is the same shape as the rest of kix DI, where
a package is explicit about what it needs and the cluster resolves which
implementation provides it (`PRINCIPLES.md:25`).

Two design notes cover pieces of this and neither is settled.
`v2_discussions/106_ops_lifecycle_verbs_and_capacity_check.md:218` proposes a
single-node module that reduces synthesized anti-affinity from `required` to
`preferred`, and marks "or strips entirely" an open question.
`v2_discussions/interesting_thoughts/69_hardware_driven_scheduling.md:148`
proposes deriving replicas, anti-affinity and PDBs from a hardware profile.
Neither proposal has a home for the zone concept itself.

Worth deciding together: where anti-affinity is declared (per package, a shared
build entry like `kix.expose`, or a post-fixpoint pass), whether a single-node
cluster drops it automatically, and what injects the failure-zone topology key.
