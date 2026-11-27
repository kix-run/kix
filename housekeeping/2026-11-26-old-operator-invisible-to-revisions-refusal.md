# 2026-11-26 · `cli/kix-cli/src/commands/operator.rs` · The refusal of an operator without the `revisions` feature cannot see an operator from Kix 0.9 or earlier.

`refuse_operator_without_revisions` refuses only when an operator published features and `revisions` is not among them. Operators before 0.10 publish no `kix.run/operator-features`, so the usual upgrade from 0.9 passes, and that operator writes `kix.run/activations` and `kix.run/applied-hash` back after the first deploy removed them. Refusing also when the current record is operator-driven would cover most installs.

Decision required from Adam: refuse on an operator-driven current record, or only document the upgrade order.
