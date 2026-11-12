# 2026-11-12 · `kix check` · A cluster command run without a cluster name does not list the clusters there are.

`kix check` with no argument prints clap's "the following required arguments were not provided: <CLUSTER>". The user then has to know about `kix list clusters`. Naming that command, or listing the clusters, in the error would save a step.
