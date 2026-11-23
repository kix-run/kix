+++
kind = "note"
packages = ["experimental/n8n"]
+++
`n8n` runs n8n 2.48.8 instead of 2.41.5, with a matching `n8nio/runners` sidecar. The first deploy restarts the main pod and the workers once, and n8n migrates the database when it starts. Workflows, credentials, and past executions carry over. Upstream documents no way back to an older version. In our test, n8n 2.48.6 started on a database that 2.48.8 had migrated and read its workflows and credentials, and n8n 2.41.5 did the same on a database from 2.48.6, so to go back, deploy the previous Kix release. Clusters must run Kubernetes 1.25 or later (see `[K1269]`).
