+++
kind = "fixed"
+++
Clusters can now include custom resources named `Activation` or `PackageInstance` from other API groups. Previously, Kix rejected the build with "the build must hold 1 deployment record" or treated those objects as its own records. Kix now treats only `Activation` and `PackageInstance` in its own API group (`kix.run`) as Kix records, and deploys, prunes, and exports resources of the same kind in other API groups like any other object.
