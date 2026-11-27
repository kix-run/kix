# 2026-11-27 · `cli/kix/src/plan/planner.rs` · After the upgrade, the plan and `kix gc` list Kix's own CRDs as leftovers the user may delete.

A Kubernetes cluster holds three Kix clusters. This Kix upgraded one of them, and an older Kix still deploys the other two. Since then, every `kix plan` and `kix gc --dry-run` of the upgraded Kix cluster prints `CustomResourceDefinition/activations.kix.run` and `CustomResourceDefinition/packageinstances.kix.run` under "Kept on the cluster (left the build, never deleted automatically)". The text below the list says "Delete them with `kubectl` if that is intended." Deleting `activations.kix.run` deletes every deployment record on the cluster.

The two CRDs left the build because Kix now installs them itself. The first deploy after the upgrade prints the same two lines once on any cluster, and there it reads as a note about the change. Here the lines stay, probably because the older Kix clusters keep their `kix.run/activations` annotation and `kix` field manager entry on the two CRDs. A local cluster with one upgraded and one older Kix cluster did not show the lines in `kix gc`, so the exact condition is not known.

The plan document already has the value `crd_installed_by_kix` for these objects. The leftover list should leave them out, or say that Kix installs them.

The same `kix gc --dry-run` output says of old deployment records that "the next deploy removes it from tracking annotations on every object". Objects no longer carry that annotation, so the sentence is out of date.
