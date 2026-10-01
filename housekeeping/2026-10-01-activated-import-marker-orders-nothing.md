# 2026-10-01 · `kix/lib/eval/cluster.nix` · An activated optional import's marker has no dependents, so nothing waits for it.

An optional import that a dependency resolves to is now active and its
marker is emitted (`activatedImports`). The consumer reads plain strings
from the import's `out` (`storageClasses.out.storageClassName`), which carry
no string context, so no `kix.run/depends-on` or package-requires entry
points at the marker. On ludo-kind the `kube-system/platform-storage` marker
appears only in the Activation's instance list: the deploy checks
`StorageClass/standard`, but a PVC built from it can be applied first.
Read-based edges were considered and not added (lib-reference-checks plan 3.11).
