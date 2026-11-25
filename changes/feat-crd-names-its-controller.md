+++
kind = "added"
library = ["scope.mkCRD", "scope.mkCRDRef"]
state = true
+++
`scope.mkCRD` and `scope.mkCRDRef` take an optional `controller`: the Deployment, StatefulSet, or DaemonSet that handles custom resources of the kind (or a list of them, or an import marker for one that runs outside Kix). Every custom resource of the kind then depends on it, so `kix deploy` creates the resource after the controller is ready, and `kix deploy --prune`, `kix rollback --prune`, `kix gc`, and the Kix operator delete the resource first and keep the controller until the resource is gone. When such a delete does not finish, the `[K2794]` message names the controller and says whether it is ready, not ready, or not on the cluster. Kix writes the controller into the custom resource's `kix.run/depends-on` annotation as a `controller:<hash>` entry; older releases of Kix order on it like any other entry. A `controller` that is not a workload fails the build when the kind is declared. Without `controller`, Kix orders and reports custom resources as before.
