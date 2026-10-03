# 2026-10-03 · `kix/packages/cnpg-cluster` · The operand peer rules select every pod with the Cluster's label, so pooler pods and instance pods reach each other on every port.

`operandEgress` and `operandIngress` select `cnpg.io/cluster=<name>`, which the operator also puts on a Pooler's PgBouncer pods and on Job pods (`pkg/specs/pgbouncer/deployments.go` upstream). `mkSelfRules` then admits all traffic among them, wider than the PostgreSQL port cnpg-pooler opens. Narrowing the peer rules to `cnpg.io/podRole=instance` needs a check of what the Job pods dial.
