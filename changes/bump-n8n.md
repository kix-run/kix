+++
kind = "note"
packages = ["experimental/n8n"]
+++
`n8n` runs n8n 2.48.5 instead of 2.41.5, with a matching `n8nio/runners` sidecar. The first deploy restarts the main pod and the workers once, and the new main instance migrates the database when it starts. Workflows, credentials, and past executions carry over. Upstream documents no way back to an older version.
