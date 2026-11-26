# 2026-11-26 · `mkSelfRules` in both network policy enforcers · Peer rules admit a workload's own pods on every port.

`mkSelfRules { selector; }` takes no ports, so a StatefulSet's peer rule (derive.nix) and the peer rules packages build for operator pods (alertmanager, clickhouse-keeper, clickhouse-cluster, stackgres-cluster, cnpg-cluster, kubevirt, victoria-metrics-alert) let peers reach each other on every port, with Cilium and with standard NetworkPolicy. The derived StatefulSet rule cannot know the peer ports; a package that does could pass them if the builder took `ports`.
