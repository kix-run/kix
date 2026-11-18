+++
kind = "fixed"
+++
When `networkPolicy.enable = true`, Kix now generates the same network policies for a CronJob as for a Job. Previously, a CronJob whose ServiceAccount had a RoleBinding or ClusterRoleBinding got no policy allowing its pods to reach the Kubernetes API server, so default deny blocked that traffic. The scorecard rules for conflicting port names (`architecture.consistentPortNames`) and hardcoded `*.svc` Service addresses (`architecture.fqdnWithoutContext`) now check ReplicationControllers too. Kix also rejects `kix.untrackedRef` with `by = "self"` on a required volume, `env` or `envFrom` reference, or `serviceAccountName` in a ReplicationController, because Kubernetes waits for that object before starting the pod.
