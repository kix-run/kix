+++
kind = "silent"
library = ["kix.lib.mkFlake"]
state = true
+++
If you apply `kix build` or `kix export --with-kix-metadata` manifests with an external tool instead of `kix deploy`, install `activations.kix.run` and `packageinstances.kix.run` on the cluster first (for example, by running `kix deploy` once or copying those two CustomResourceDefinitions from a cluster Kix has deployed). Cluster builds no longer emit those two CRDs because Kix installs them directly when a deploy starts, and Kix filters them out when loading builds from earlier versions during rollback. Because `Activation` and `PackageInstance` manifests no longer list those CRDs in `kix.run/depends-on`, the first deploy after upgrading updates their metadata once without restarting any workloads.
