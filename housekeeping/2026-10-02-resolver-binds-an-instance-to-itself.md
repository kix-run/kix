# 2026-10-02 · `kix/lib/eval/resolve.nix` · A dependency named like one of the instance's own aliases resolves to the instance itself, and the build overflows the stack.

When an instance's `aliases` include a dependency name it also takes (a
`mayastor` instance aliased `storageClasses` with a `storageClasses ? null`
argument) and no explicit `deps` entry names another instance, the resolver
binds the dependency to the requester. The build then ends in "stack
overflow; max-call-depth exceeded" with no hint of the cause, even when the
package never reads the dependency: each workload's edge analysis walks every
resolved dependency's parts (`_depResourcesForEdges` in
`kix/lib/eval/instance.nix`), which are the instance's own. `mayastor`
refuses the case before that happens by reading its own `aliases` and `deps`
from `clusterConfig.instances` (`kix/packages/mayastor/etcd.nix`).
