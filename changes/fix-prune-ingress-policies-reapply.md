+++
kind = "note"
+++
On the first deploy after upgrading, Kix re-applies network policies whose
`spec` references another resource's pods, along with the resources that depend
on those policies (such as Deployments, Jobs, Services, and Ingresses). Kix no
longer records dependencies from a network policy's `spec`, so only `kix.run/`
annotations change on these resources. No pods restart, no Jobs run again, and
no traffic rules change.
