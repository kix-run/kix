# 2026-10-18 · `kix plan` · The dry-run preview runs custom resources through the old operator's webhook.

When an operator upgrade adds RBAC its webhook needs, the preview of a custom resource fails before the deploy would have applied that RBAC. On ludo the StackGres 1.19.0 webhook lacked `leases`, so `SGCluster/postgres` was "denied by admission webhook" and the deploy refused to start. Applying the new `stackgres-operator` ClusterRole by hand first was the workaround.
