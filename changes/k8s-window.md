+++
kind = "added"
library = ["meta.k8s.supported", "kix.version"]
+++
This Kix release supports Kubernetes 1.36 and 1.37, and every stable package builds on both versions. Setting `k8sVersion` outside 1.36 to 1.37 emits a warning without stopping the build, though individual packages still fail the build when `k8sVersion` falls outside their `meta.k8s.minVersion` or `meta.k8s.maxVersion` bounds. Package authors can also set `meta.k8s.supported` (`minVersion`, `maxVersion`, and `source`) to warn when `k8sVersion` falls outside the Kubernetes versions the upstream project supports or tests. Inside `build`, packages can compare version strings such as `clusterConfig.k8sVersion` with `kix.version.atLeast` and `kix.version.atMost`.
