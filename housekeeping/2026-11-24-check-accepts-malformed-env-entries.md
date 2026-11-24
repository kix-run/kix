# 2026-11-24 · `kix check` · A container env entry shaped `{ name; valueFrom.valueFrom.secretKeyRef; }` passes evaluation, the validation checks, and the scorecard.

Writing `{ name = "X"; valueFrom = secret.out.keyRef "k"; }` nests the
`valueFrom` that `keyRef` already returns. `kix check` reported the nats
test cluster clean with that StatefulSet, and only a unit test that read
the env caught it. The API server would refuse the object at deploy, after
the plan. `kix check` runs no schema check of built-in kinds; the
`schema-cluster-<name>` flake check (kubeconform, `scripts/cluster-checks.sh`)
is separate, and whether it catches this shape is untested.
