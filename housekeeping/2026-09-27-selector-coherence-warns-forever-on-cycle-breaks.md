# 2026-09-27 · `kix/lib/rules/architecture.nix` · `architecture.selectorCoherence` warns on every build for a Service that must break a cycle, and nothing can mark the break as intended.

Five Services cannot read their workload's `out.selector` without an
evaluation cycle: harbor `harbor-core` and `harbor-jobservice` (core's
ConfigMap names both), ingress-nginx `ingress-nginx` and
`ingress-nginx-admission` (the controller Deployment `requires` its
Service for `--publish-service`), and valkey `<name>-headless` with
Sentinel on (the start scripts resolve it before any pod is Ready). Each carries a comment
explaining why, yet the rule fires on the literal and on `rawSelector`
alike, so these warnings stay in every package-eval run and a new,
accidental literal selector is lost among them.

- Hit again 2026-10-02 by `kix/packages/mayastor`: the etcd headless Service selects with the StatefulSet's `rawSelector` because the members' env reads its `out.fqdn`, and `architecture.selectorCoherence` warns on it in every build.
- Hit again 2026-10-03 by `kix/packages/spegel`: the `<name>-bootstrap` headless Service selects with the DaemonSet's `rawSelector` because the registry's `--dns-bootstrap-domain` reads its `out.fqdn`, and the rule warns on it in every build.
