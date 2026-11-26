+++
kind = "silent"
+++
On existing `gke-autopilot` clusters, set `"premium-rwo"` explicitly on any instance that already has volumes provisioned with the cluster's default StorageClass before you deploy. The `gke-autopilot` flavor's `platform-storage` import now sets the default StorageClass to `standard-rwo` (GKE Autopilot's default, verified on a live cluster where `standard-rwo` carried `storageclass.kubernetes.io/is-default-class: "true"` and `premium-rwo` did not) instead of `premium-rwo`. Instances that rely on the cluster default now request `standard-rwo`, and Kubernetes rejects changes to the StorageClass of an existing PersistentVolumeClaim or StatefulSet volume claim template.
