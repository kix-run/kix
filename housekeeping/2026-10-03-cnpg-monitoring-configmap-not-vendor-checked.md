# 2026-10-03 · `kix/packages/cnpg-operator/monitoring` · The vendored default monitoring ConfigMap is outside `vendor-crds.py --check`.

`scripts/vendor-crds.py` vendors only CRDs and RBAC roles, so the copy of
`cnpg-default-monitoring` taken from the CNPG release manifest is replaced by
hand on a version bump. Nothing fails when it goes stale, and the queries then
drift from the operator version. Any other package that vendors a non-CRD
upstream object has the same gap.
