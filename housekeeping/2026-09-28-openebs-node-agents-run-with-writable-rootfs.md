# 2026-09-28 · `kix/packages/openebs` · Five openebs node containers still run with a writable root filesystem.

`security.readOnlyRootfs` warns on io-engine, csi-node, agent-ha-node and
the ZFS and LVM node plugins. They are privileged host agents. The ZFS and
LVM plugins shell out to zfs and lvm tooling, and lvm keeps archive,
backup and lock state under /etc/lvm and /run; nothing on kind exercised
those paths. The three Mayastor agents cannot start on kind (hugepages,
read-only sysfs, no /run/udev), so their write paths could not be
observed. Mapping them needs a run on a real storage node.
