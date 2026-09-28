# 2026-09-27 · `kix/lib/rules/architecture.nix` · `architecture.selectorCoherence` warns on every build for a Service that must break a cycle, and nothing can mark the break as intended.

Seven Services cannot read their workload's `out.selector` without an
evaluation cycle: harbor `harbor-core` and `harbor-jobservice` (core's
ConfigMap names both), ingress-nginx `ingress-nginx` and
`ingress-nginx-admission` (the controller Deployment `requires` its
Service for `--publish-service`), openebs `openebs-etcd-headless` and
`openebs-nats` (the pods dial their own headless Service), and openebs
`openebs-obs-callhome-stats` (the obs-callhome Deployment dials it by
`out.name`). Each carries a comment explaining why, yet the rule fires
on the literal and on `rawSelector` alike, so these warnings stay in
every package-eval run and a new, accidental literal selector is lost
among them.
