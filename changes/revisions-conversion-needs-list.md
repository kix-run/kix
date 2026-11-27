+++
kind = "error"
state = true
id = "K9558"
+++
For the first deploy of an existing Kix cluster after upgrading, run with an account that has cluster-wide `list` permission on every resource kind the cluster deploys (or grant that permission temporarily for the first deploy). Deployment records written by Kix 0.9 or earlier do not store full object names and API groups, so Kix lists all Kix-labeled objects across the cluster once to build `PackageInstanceRevision` resources for those records. If the account lacks cluster-wide `list` permission on any kind (such as accounts restricted to namespaced Roles), `kix plan`, `kix deploy`, and the Kix operator stop with `[K9558]` before making any changes and name the missing kinds; subsequent deploys read the revisions and work with namespaced permissions as before.
