# 2026-11-13 · `kix-operator` · An Activation applied without `kix deploy --operator` has no receipt, so the operator's required-stop check passes it.

The operator reads the Kix of the last deploy from the Active record's receipt. Only the CLI writes receipts, including for `kix deploy --operator` (`commands/operator.rs`, `apply_activation`). A cluster driven only by Activations applied some other way, such as GitOps, has no version to compare, and an operator upgrade can skip a required stop unnoticed.
