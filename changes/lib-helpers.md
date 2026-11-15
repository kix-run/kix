+++
kind = "fixed"
+++
A CronJob now gets the same network policies as a Job when network policy is on. Before, a CronJob whose ServiceAccount is bound to a role got no policy letting its pods reach the Kubernetes API server, so those pods could not reach it under default deny. The architecture scorecard rules and the check that a pod does not require an object it creates now also cover ReplicationControllers, like the other kinds that create pods.
