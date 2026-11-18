+++
kind = "changed"
packages = ["victoria-metrics-cluster", "victoria-metrics-agent", "victoria-metrics-alert"]
+++
No configuration changes are needed. On the first deploy after you upgrade, the VictoriaMetrics operator restarts affected pods in `victoria-metrics-cluster`, `victoria-metrics-agent`, and `victoria-metrics-alert` once. On multi-node clusters, multi-replica components in those packages now spread pods evenly with `topologySpreadConstraints` (`maxSkew = 1`): spreading is required (`DoNotSchedule`) across nodes at `node` availability and across zones at `zone` availability, and best-effort (`ScheduleAnyway`) otherwise. Previously, preferred `podAntiAffinity` let Kubernetes place replicas on the same node or in the same zone. Single-replica components no longer get a `PodDisruptionBudget`. Setting `topologySpreadConstraints` in `extraSpec` or `alertmanager.extraSpec` still replaces the default spread constraints.
