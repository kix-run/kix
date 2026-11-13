+++
kind = "fixed"
+++
`kix deploy`, `kix plan`, and `kix rollback` no longer stop when an admission webhook cannot reach its Service and the same deploy writes that Service or another object of the package that serves it, such as the operator's Deployment. Before, if a first deploy of an operator failed after it registered its webhook but before it created the webhook's Service, every later deploy stopped before applying anything, with `service "..." not found` for each object the webhook checks. The plan now lists these objects under "Not checked by the dry run", with the reason `webhook_backend_written_by_this_deploy` in `-o json`. A webhook that answers and denies a write still stops the deploy.
