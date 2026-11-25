+++
kind = "changed"
packages = ["cnpg-operator", "experimental/db-operator", "experimental/keda"]
+++
`cnpg-operator`, `db-operator`, and `keda` name their operator as the `controller` of every custom resource kind they define. A prune that removes custom resources of these kinds together with the operator now deletes the custom resources first and keeps the operator until they are gone, and a stuck delete names the operator and says whether it is ready. The first deploy after the upgrade applies each custom resource of these kinds again, because its `kix.run/depends-on` annotation changes.
