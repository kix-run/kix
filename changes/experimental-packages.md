+++
kind = "error"
id = "K0549"
packages = ["experimental/alertmanager", "experimental/arc", "experimental/arc-runner-set", "experimental/caddy", "experimental/cdi", "experimental/cert-manager", "experimental/cilium", "experimental/clickhouse", "experimental/clickhouse-cluster", "experimental/clickhouse-database", "experimental/clickhouse-keeper", "experimental/clickhouse-logs", "experimental/clickhouse-operator", "experimental/cloudflared", "experimental/cluster-issuer", "experimental/cnpg-barman-cloud", "experimental/cnpg-database", "experimental/cnpg-pooler", "experimental/coredns", "experimental/descheduler", "experimental/dns-exporter", "experimental/envoy-gateway", "experimental/external-dns", "experimental/external-secrets", "experimental/falco", "experimental/filebrowser", "experimental/firezone", "experimental/immich", "experimental/immich-machine-learning", "experimental/infisical-operator", "experimental/ingress-nginx", "experimental/keycloak", "experimental/kubevirt", "experimental/loki", "experimental/loki-logs", "experimental/mayastor", "experimental/metabase", "experimental/metrics-server", "experimental/n8n", "experimental/oidc-client", "experimental/openbao", "experimental/otel-collector", "experimental/plausible", "experimental/prometheus", "experimental/prometheus-default-rules", "experimental/prometheus-operator", "experimental/rabbitmq-cluster", "experimental/rabbitmq-operator", "experimental/reflector", "experimental/reloader", "experimental/secret-echo", "experimental/service-ref", "experimental/smartctl-exporter", "experimental/snapshot-controller", "experimental/spegel", "experimental/stackgres-cluster", "experimental/stackgres-database", "experimental/stackgres-object-storage", "experimental/stackgres-operator", "experimental/tailscale", "experimental/tempo", "experimental/traefik", "experimental/vaultwarden", "experimental/velero", "experimental/volsync", "experimental/zfs-localpv"]
library = ["kix.contracts.experimental.oidcProvider", "kix.contracts.experimental.otlpEndpoint", "kix.modules.experimental.monitoring"]
+++
Most packages are experimental now, so they may change in any release. Only
`cnpg-cluster`, `cnpg-operator`, `echo-server`, `grafana`, `harbor`,
`kube-state-metrics`, `node-exporter`, `persistent-volume-claim`,
`priority-class`, `secret`, `secret-ref`, `storage-classes`, `valkey`,
and the four `victoria-metrics-*` packages are stable. Write
`packages.experimental.<name>` for every other package, such as
`packages.experimental.cert-manager`. The contracts `oidcProvider` and
`otlpEndpoint` are `kix.contracts.experimental.<name>`, and the
monitoring module is `kix.modules.experimental.monitoring`. The old names
fail with an error that gives the new one. `availablePackages = packages`
now offers only the stable packages. If Kix then reports a dependency with no
matching instance, add the experimental package that provided it, such as
`availablePackages = packages // { inherit (packages.experimental) cert-manager; };`.
