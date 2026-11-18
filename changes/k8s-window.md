+++
kind = "added"
library = ["meta.k8s.supported"]
+++
This release supports Kubernetes 1.36 and 1.37, and every stable package builds on both versions. If a cluster sets `k8sVersion` outside 1.36 to 1.37, this release's version check only emits a warning, but a package can still fail the build through its own `meta.k8s.minVersion` or `meta.k8s.maxVersion`. Package authors can also set `meta.k8s.supported` (`minVersion`, `maxVersion`, and `source`) to record the Kubernetes versions the upstream project supports or tests. A cluster whose `k8sVersion` falls outside `meta.k8s.supported` builds with a warning naming that range and its source, while top-level `meta.k8s.minVersion` and `meta.k8s.maxVersion` continue to fail the build when a package is known to fail on that Kubernetes version.
