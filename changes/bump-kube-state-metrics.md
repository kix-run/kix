+++
kind = "changed"
packages = ["kube-state-metrics"]
+++
`kube-state-metrics` now deploys kube-state-metrics 2.20.0, up from 2.19.1. It adds series for ValidatingAdmissionPolicy, MutatingAdmissionPolicy, and their bindings, and the package's ClusterRole now lets it read them. `kube_pod_status_reason` now has a series only for the reason a pod has. Before, every pod had a series for every reason, with the value 0 for the reasons it did not have. A query or dashboard that reads those zero values, such as `kube_pod_status_reason{reason="Evicted"} == 0`, now returns nothing. Queries that sum or compare with `> 0` give the same result. The first deploy after you upgrade restarts the kube-state-metrics pod once.
