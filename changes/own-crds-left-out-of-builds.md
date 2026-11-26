+++
kind = "silent"
library = ["kix.lib.mkFlake"]
state = true
+++
Build output no longer contains the `activations.kix.run` and `packageinstances.kix.run` CustomResourceDefinitions, because Kix installs them itself when it deploys. If you apply `kix build` or `kix export` output with another tool, install the two CRDs another way first, for example by running `kix deploy` once or by copying them from a cluster Kix has deployed. Kix leaves the two CRDs out of older builds it loads too, so a rollback to a build from an earlier release does not apply them again. Every PackageInstance and Activation in a build loses one entry of `kix.run/depends-on`, so the first deploy after the upgrade writes each of them once. That write changes only metadata and restarts nothing.
