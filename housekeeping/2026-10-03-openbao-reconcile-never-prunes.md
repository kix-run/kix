# 2026-10-03 · `kix/packages/openbao` · Policies and roles removed from the config stay in OpenBao.

The reconcile Job (`reconcile.sh`) creates and updates the declared policies, Kubernetes auth roles, and secrets engines, and deletes nothing. A role removed from `kubernetesAuth.roles` keeps granting logins until someone deletes it in OpenBao. The Job's log lists undeclared policies and roles, but nothing fails and the deploy shows no drift. A secrets engine whose options change is also left as it was.
