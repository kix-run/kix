+++
kind = "fixed"
library = ["kix.flavors.eks", "kix.flavors.gke", "kix.flavors.gke-autopilot", "kix.flavors.aks"]
+++
If your cluster uses `kix.flavors.eks`, `kix.flavors.gke`, `kix.flavors.gke-autopilot`, or `kix.flavors.aks`, you can remove `eks.amazonaws.com`, `iam.gke.io`, or `azure.workload.identity` from `scorecard.knownAnnotationDomains` when listed for that cluster's cloud. Each flavor now declares its cloud identity annotation domain (`eks.amazonaws.com` on `eks`, `iam.gke.io` on `gke` and `gke-autopilot`, and `azure.workload.identity` on `aks`), so the `architecture.annotationDomainOwnership` rule accepts those annotations without warning.
