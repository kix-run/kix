+++
kind = "fixed"
+++
On clusters deployed with an earlier version of Kix, `kix plan`, `kix deploy`, and `kix gc` no longer list Kix's `activations.kix.run` and `packageinstances.kix.run` CustomResourceDefinitions as objects that left the build or suggest deleting them with `kubectl` (deleting `activations.kix.run` would delete every deployment record on the cluster). `kix status` also no longer reports those two CRDs as missing. Earlier versions of Kix recorded both CRDs as deployed objects, whereas Kix now installs them directly and ignores them when reading earlier deployment records.
