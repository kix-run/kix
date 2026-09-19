# 2026-09-19 · `kix/packages/openebs` · The ZFS and LVM CSIDrivers and PriorityClasses are cluster-scoped resources with fixed upstream names, so two openebs instances in one cluster collide.

`openebs-zfs-csi-controller-critical`, `openebs-zfs-csi-node-critical`,
the two LVM classes and the `zfs.csi.openebs.io` / `local.csi.openebs.io`
CSIDrivers all carry the chart's literal name, while the mayastor
PriorityClass is `${name}-cluster-critical`. The package should settle on
one convention; the CSIDriver names are fixed by the drivers themselves,
so the PriorityClasses are the ones with a choice.
