+++
kind = "fixed"
+++
`kix check` now lists more warnings from the Kix library that it used to drop when the build succeeded. These include a LoadBalancer Service built when `cluster.roles.loadBalancer.binding` is unset, a HorizontalPodAutoscaler built when `cluster.roles.metricsApi.binding` is unset, a workload that needs a cluster capability the cluster definition does not set, a workload whose replicas may not fit on one node, a workload capped by `availability.max`, a workload that names a Service without using its address, and the network policy warnings of `kix.expose`. The list also appears in the Activation record, so the first deploy after an upgrade updates the Activation of a cluster that gains one of these warnings.
