+++
kind = "error"
state = true
id = "K9558"
+++
The first deploy of a Kix cluster after the upgrade needs `list` on every kind the cluster deploys, across the whole cluster, when its deployment records do not name their objects. Records written by Kix 0.9 or earlier do not name them. Kix then finds the objects of each such record by listing every object that carries its label, to give the record revisions. When the account may not list one of those kinds in every namespace, `kix plan`, `kix deploy`, and the Kix operator stop with `[K9558]` before they change anything, and name the kinds. This affects accounts with namespaced roles, which earlier versions supported for deploys. Grant the account `list` on those kinds across the cluster for the first deploy, or run that deploy once with an account that may list them. Later deploys read the revisions and need no more than before.
