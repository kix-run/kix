# 2026-09-19 · `kix/lib/scope/builders.nix` · A CronJob has no typed builder, so `kix/packages/stackgres-pgpass-perms-fix` builds one with `scope.mkResource` and it never reaches `sealWorkload`.

`mkResource` refuses Deployment, StatefulSet, DaemonSet and Job, but a
CronJob slips through: no pod-spec validators, no DNS ordering and no
network-policy edges for the pods it runs. `helm.nix` skips the kind
too. Wants an `mkCronJob` that seals `spec.jobTemplate.spec.template`
the way `mkJob` seals `spec.template`, and then one more kind on the
refusal list.
