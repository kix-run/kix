# 2026-11-03 · `kix/packages/rabbitmq-operator` · The operator's CPU limit equals its request, so it is throttled whenever it is busy.

Its default `resources` cap CPU at the 200m it requests, so the operator can never use more. cnpg-operator had the same cap (100m) and raised CPU-throttling alerts during a rolling restart of its Clusters. The other operator packages request little and allow 500m to 1 core.
