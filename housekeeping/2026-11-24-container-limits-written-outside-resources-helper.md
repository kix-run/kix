# 2026-11-24 · `kix/packages` · Seventeen containers write their limits as literals, so `cluster.defaultLimits` cannot drop them.

`cluster.defaultLimits.cpu = false` acts only in `kix.options.resources`. These containers set `limits` directly, so they keep a CPU and memory limit (plausible a memory limit only) on a cluster that turned defaults off, and the user has no option to clear them:
- CRD wait Jobs: cnpg-operator/default.nix:837, experimental/rabbitmq-operator/default.nix:682, experimental/stackgres-operator/default.nix:884, experimental/external-secrets/webhook.nix:520, experimental/db-operator/default.nix:867, experimental/cert-manager/startupapicheck.nix:100.
- Init and helper containers: grafana/default.nix:258, echo-server/default.nix:207, harbor/registry.nix:286, experimental/clickhouse-database/default.nix:549, experimental/mayastor/common.nix:111 (`initResources`), experimental/n8n/default.nix:574, experimental/velero/workloads.nix:200, experimental/immich/default.nix:787, experimental/plausible/default.nix:576, experimental/openbao/reconcile.nix:196.
- Helm values: experimental/smartctl-exporter/default.nix:82.

mayastor/node.nix:167 forces `limits = ioEngineCompute` on io-engine (CPU equal to the request, for guaranteed QoS). That one looks deliberate. Packages that import a Helm chart keep whatever the chart renders.
