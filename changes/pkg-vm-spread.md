+++
kind = "changed"
packages = ["victoria-metrics-cluster", "victoria-metrics-agent", "victoria-metrics-alert"]
+++
The VictoriaMetrics packages spread their pods by the cluster's availability level, as Kix does for the workloads it renders. Each component with more than one replica gets topology spread constraints: at `node` its replicas must run on different nodes, and at `zone` in different zones. Before, a preferred anti-affinity let replicas share a node or zone. A component with one replica no longer gets a PodDisruptionBudget. A `topologySpreadConstraints` set through `extraSpec` still replaces the derived spread. The operator restarts the affected pods once on the first deploy after the upgrade.
