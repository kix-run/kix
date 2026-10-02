# 2026-10-02 · `kix/lib/eval` · Two workloads can mount one ReadWriteOnce `persistent-volume-claim` instance, and evaluation passes.

A `storage` dependency resolves by alias in the consumer's namespace, so two
packages that each take `storage` (vaultwarden and grafana, verified) both
bind the one claim and both pods mount it. On a ReadWriteOnce volume the
second pod cannot start on another node, and two programs write one
directory. Nothing checks for it: lib-reference-checks considered a check
for a shared RWO claim and did not add one, so only docs guard it. The loki
package header and kix.modules.monitoring give Loki's claim its own name and
alias for this reason.
