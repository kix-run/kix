# 2026-10-02 · `cli/kix-cli/src/commands/deploy.rs` · A `kix deploy` whose activation is unchanged never mentions OnDelete pods still on the old template.

Only the deploy that applies a new io-engine template prints "N pods pending
manual restart (OnDelete)". The next plain deploy says "activation identical
to active ... Nothing to apply" and exits, so an operator who missed that one
line has no later reminder; `--reconcile` brings it back. Seen in the W6
K-mayastor kind run with two stale io-engine pods.
