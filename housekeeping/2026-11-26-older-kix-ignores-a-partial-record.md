# 2026-11-26 · `cli/kix/src/cluster/activation/` · A Kix from before `--only` ignores a `Partial` record.

A release without the `Partial` phase neither folds such a record into its
plan nor marks it `Superseded`. A deploy with `--only` writes no deploy
receipt, so the check for "deployed by a newer Kix" does not stop the older
Kix when the last whole deploy was its own. Its next deploy then leaves in
place what `--only` applied from another build, and does not delete what
`--only` created. Options: have a deploy with `--only` write the receipt,
or accept it as the cost of downgrading.
