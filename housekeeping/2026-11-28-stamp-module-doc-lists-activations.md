# 2026-11-28 · `cli/kix-core/src/eval/stamp.rs` · The module comment says stamping writes `kix.run/activations` during apply.

Kix no longer writes `kix.run/activations` anywhere, and the five annotations stamping does write never reach the cluster (`manifest::sent`). The comment leads a reader to look for the annotation on live objects.
