+++
kind = "changed"
packages = ["cnpg-operator", "experimental/db-operator", "experimental/keda"]
+++
`cnpg-operator`, `db-operator`, and `keda` now record their operator as the `controller` for every custom resource kind they define. No configuration changes are needed, though the first deploy after upgrading re-applies existing custom resources of these kinds to update their `kix.run/depends-on` annotation. When you prune custom resources together with their operator, Kix now deletes the custom resources first and does not delete the operator until they are gone. If a delete times out (`[K2794]`), Kix names the operator and reports whether it is ready.
