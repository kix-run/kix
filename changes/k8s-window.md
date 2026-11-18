+++
kind = "added"
library = ["meta.k8s.supported"]
+++
A package can now say which Kubernetes versions upstream states support for, in `meta.k8s.supported`, apart from the versions it is known to fail on. A cluster whose `k8sVersion` is outside `supported` builds with a warning that names upstream's range and its source. `meta.k8s.minVersion` and `maxVersion` still refuse the cluster. Each Kix release also names the Kubernetes versions it supports, 1.36 and 1.37 in this one. Every stable package accepts both, and a cluster whose `k8sVersion` is outside them gets a warning.
