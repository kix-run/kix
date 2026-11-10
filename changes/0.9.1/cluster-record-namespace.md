+++
kind = "added"
+++
`cluster.recordNamespace` names the namespace for the `PackageInstance` record of each instance under a `_`-prefixed key such as `instances._cluster`. The default is `kube-system`. Before, Kix wrote these records to a namespace named `_cluster`, which Kubernetes refuses, so a deploy of such an instance failed. Kix does not create this namespace. On a cluster that refuses writes to `kube-system`, such as GKE Autopilot, set another namespace that exists.
