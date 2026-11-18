+++
kind = "changed"
packages = ["experimental/arc-runner-set"]
+++
`arc-runner-set` now runs the GitHub Actions runner 2.338.2 instead of 2.337.0. GitHub stops sending jobs to a runner that falls too far behind its latest release, so this keeps the runners getting jobs. The runner's own tools, such as `hashFiles()`, now use Node 24 instead of Node 20. To keep Node 20 for them for now, set `ACTIONS_RUNNER_FORCED_INTERNAL_NODE_VERSION = "node20"` in `env`. Actions that name `node20` or `node24` in their own files are not affected. The image also ships Docker 29.9.2 and Buildx 0.38.1. The first deploy after you upgrade changes the runner set's pod template, so the controller replaces the listener and the idle runners. Jobs that are running finish on the old runner.
