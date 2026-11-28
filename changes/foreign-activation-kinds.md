+++
kind = "fixed"
+++
A build may hold an `Activation` or `PackageInstance` object of another API group. Kix used to refuse such a build with "the build must hold 1 deployment record", or treat the object as one of its own records. Kix now treats only the `Activation` and `PackageInstance` kinds of its own API group (`kix.run`) as its records, and deploys, prunes, and exports another group's kinds of those names like any other object.
