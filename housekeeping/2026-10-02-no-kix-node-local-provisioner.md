# 2026-10-02 · `kix/packages` · Kix has no node-local provisioner other than zfs-localpv.

With the openebs hostpath provisioner deleted, a cluster without ZFS has no
Kix package that provisions node-local volumes. Mayastor's etcd needs a class
that is not Mayastor's, and on kubeadm or RKE2 the stranger must install
local-path-provisioner outside Kix and import its class
(`kix.mkImport { out.storageClassName = "local-path"; }`), as the
install-mayastor how-to describes.
