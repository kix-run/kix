# 2026-09-20 · `kix/lib/eval/` auto-instantiation · The stock StorageClass catalogue arrives even when nothing needs it.

A cluster whose only claim names its class outright
(`persistent-volume-claim` with `config.storageClassName = "local-path"`)
still gets `storage-classes` auto-instantiated, and that package's
default `lbs1-pool1-2x` class carries
`storageclass.kubernetes.io/is-default-class: "true"`. Deploying that to
a cluster whose default class is something else silently moves the
default. Setting `cluster.roles.storageClasses.binding = "absent"` does
not stop it either. Seen while writing `clusters/test-ingress-netpol.nix`,
which works around it with an import that fills the role. The demand
comes from the PVC package taking `storageClasses` as an optional dep;
an explicit `storageClassName` should retire that demand.
