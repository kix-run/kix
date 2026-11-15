+++
kind = "changed"
packages = ["victoria-metrics-cluster", "victoria-metrics-agent", "victoria-metrics-alert"]
+++
The VictoriaMetrics packages place their pods by the cluster's availability level, as Kix places the workloads it renders. Each component with more than one replica gets topology spread constraints: at `node` its replicas must run on different nodes, and at `zone` in different zones. Before, they had a preferred anti-affinity that let replicas share a node. A component with one replica no longer gets a PodDisruptionBudget. The operator restarts the affected pods once on the first deploy after the upgrade. `extraSpec` refuses `topologySpreadConstraints`.
