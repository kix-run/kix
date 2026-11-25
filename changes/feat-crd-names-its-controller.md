+++
kind = "added"
library = ["scope.mkCRD", "scope.mkCRDRef"]
state = true
+++
Package authors can now pass an optional `controller` argument to `scope.mkCRD` and `scope.mkCRDRef` to name the Deployment, StatefulSet, or DaemonSet that reconciles custom resources of that kind (or a list of them, or an import marker for a workload outside Kix; any other value fails the build when the kind is declared). Existing declarations without `controller` continue to work unchanged. When `controller` is set, `kix deploy` waits for the controller before creating custom resources of that kind, and `kix deploy --prune`, `kix rollback --prune`, `kix gc`, and the Kix operator delete those custom resources before removing the controller. If a delete times out (`[K2794]`), Kix names the controller and reports whether it is ready, not ready, or not on the cluster. Kix stores this link as `controller:<hash>` in `kix.run/depends-on`, which older versions of Kix still respect for deploy and delete order.
