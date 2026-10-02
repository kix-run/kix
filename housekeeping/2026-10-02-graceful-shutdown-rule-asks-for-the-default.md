# 2026-10-02 · `kix/lib/rules/reliability.nix` · `reliability.gracefulShutdown` reports every workload that omits `terminationGracePeriodSeconds`, so packages restate the Kubernetes default of 30 to silence it.

The rule treats an unset field like 0, but Kubernetes applies 30 seconds when
the field is absent. snapshot-controller and both zfs-localpv workloads set
`terminationGracePeriodSeconds = 30` only for this rule, and a reviewer read
it as a restated default. The rule could accept an unset field, or ask only
for workloads whose shutdown needs a different value.
