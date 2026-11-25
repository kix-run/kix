+++
kind = "silent"
+++
On `gke-autopilot`, the `platform-storage` import now names `standard-rwo`, which Google documents as the default StorageClass on Autopilot. Before, it named `premium-rwo`. Packages that use the cluster's default class now request `standard-rwo`. Kubernetes cannot change the class of an existing PersistentVolumeClaim or StatefulSet volume claim template, so a deploy that would change one fails. To keep `premium-rwo` for an instance, set it as that instance's storage class.
