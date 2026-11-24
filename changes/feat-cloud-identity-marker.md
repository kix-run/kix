+++
kind = "note"
library = ["kix.flavors.eks", "kix.flavors.gke", "kix.flavors.gke-autopilot", "kix.flavors.aks"]
+++
No action is needed on clusters using `kix.flavors.eks`, `kix.flavors.gke`, `kix.flavors.gke-autopilot`, or `kix.flavors.aks`. The first deploy after upgrading creates one new `PackageInstance` record (`kube-system/cloud-identity`, or `gke-managed/cloud-identity` on `gke-autopilot`) for the platform's cloud identity integration and leaves existing workloads unchanged.
