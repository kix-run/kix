+++
kind = "note"
state = true
+++
On the first deploy after upgrading, Kix updates the `PackageInstance` resource for each instance of a built-in package to add `spec.package`. This does not restart any workloads.
