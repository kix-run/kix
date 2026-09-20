# 2026-09-20 · `kix/packages/openebs` · The ZFS and LVM node label sets carry a literal `name` label, so two instances share it.

`zfsNodeLabels` sets `name = "openebs-zfs-node"` and `lvmNodeLabels` sets
`name = "openebs-lvm-node"` (`default.nix` lines 53 and 75). Both are
literals rather than derived from `scope.instanceName`, so two openebs
instances in one namespace stamp the same value on their node-side
resources. The `app.kubernetes.io/instance` label beside them still differs,
so a selector carrying both still tells the two apart; one selecting on
`name` alone does not.

This is a judgement call rather than a clear bug, which is why it is here
and not fixed: the values are the upstream chart's own convention, and the
CSI node drivers may select on them, so deriving them from the instance name
could break the driver the way renaming the CSIDrivers would. The
cluster-scoped PriorityClasses next to them were a different case and were
fixed on 2026-09-20, because nothing outside the package reads those names.
