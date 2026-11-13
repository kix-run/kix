# 2026-11-13 · `kix/lib/eval/cluster.nix` · A dormant `optional = true` instance still fails the cluster when a required dependency has no active provider.

`phase1Instances` covers every instance in `mergedInstances`, dormant ones
too, and `buildConfigInjections` reads `resolvedTargets.<arg>.found` for each.
That runs `resolveArg` against `resolutionIndex`, which holds active instances
only. So a dormant instance whose package needs `database` stops evaluation
with "kix-pins/worker: dependency 'database' has no matching instance in
namespace 'kix-pins'", even though it deploys nothing. When a dormant
`database` instance is declared, the same error tells the user to declare an
instance named 'database', which already exists. Found while testing issue 86.
