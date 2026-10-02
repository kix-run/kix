# 2026-10-02 · `cli/kix/src/cluster/scheduler.rs` · `kix deploy --reconcile` deletes and reruns every `kix.run/rerun: on-change` Job and reports it as "changed since the last run".

On an unchanged build, `--reconcile` tags each rerun Job `Recreate`, finds it live, and recreates it with the reason "changed since the last run" (W6 kind run K3, `Job/cert-manager-startupapicheck`). Nothing changed, so the reason is wrong, and every health-check Job runs again on a drift heal. Everything gated on such a Job (cert-manager's ClusterIssuers and Certificates) waits for it again.
