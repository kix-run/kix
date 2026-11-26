+++
kind = "note"
+++
The first deploy after upgrading applies some network policies again, along
with the objects that depend on them, such as Deployments, Jobs, Services, and
Ingresses. These are the policies whose `spec` names another object's pods,
which no longer count as their dependencies. Only Kix's own `kix.run/`
annotations change on these objects, so no pod restarts, no Job runs again,
and no traffic rule changes.
