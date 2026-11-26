# 2026-11-26 · `cli/kix-cli/src/commands/gc/` · Soft `kix gc` reads which Kix cluster deploys what three times in one run.

Each read lists every head, every Activation record, and every revision on the Kubernetes cluster. On a cluster with many records this triples the list requests of one gc run for no gain, since the three reads happen within moments of each other.
