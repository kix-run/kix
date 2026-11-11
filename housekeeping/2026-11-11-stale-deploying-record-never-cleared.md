# 2026-11-11 · `cli/kix/src/cluster/ops/record.rs` · A deployment record left in Deploying by a killed run is never cleared, and a second deploy is not refused.

A deploy killed before it marks its record Failed leaves it Deploying. Later
deploys print a note, skip folding in failed deployments, and finish without
touching that record, so the note appears on every run until someone runs the
`kubectl patch` it prints. `kix deploy` also does not refuse to start while
another deploy is in progress, which
`docs/src/content/docs/reference/cli/deploy-apply.mdx` says it does.
