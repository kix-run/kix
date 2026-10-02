# 2026-10-01 · `kix/packages/zfs-localpv` · The node `zfs-plugin` container runs with a writable root filesystem, so `security.readOnlyRootfs` warns on every build.

The plugin is privileged and runs `zfs` and `mkfs` through `chroot /host`.
Which paths inside its own image it writes (mkfs helpers, temporary files)
was not observed: kind nodes have no ZFS pool, so no volume operation ran.
Mapping them needs a run on a node with a pool.
