+++
kind = "added"
library = ["scope.mkCRD", "scope.mkCRDRef", "scope.mkCR"]
+++
A custom resource's `readiness` can now say where its controller reports the generation it has acted on, and when the running workload is waiting for a restart. `observedGeneration = "/status/<field>"` makes `kix deploy` wait on that field instead of `status.observedGeneration`, including while the field is absent, and `observedGeneration = false` says the kind reports none. `pendingRestart` names the state in which the controller has accepted the spec and the running workload keeps the previous one, such as KubeVirt's `RestartRequired=True`. `kix deploy` then reports the resource as ready with a restart pending and goes on. `scope.mkCR` also takes `readiness` for one resource, which replaces the kind's rule and is checked the same way.
