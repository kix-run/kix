+++
kind = "fixed"
library = ["kix.flavors.eks", "kix.flavors.gke", "kix.flavors.gke-autopilot", "kix.flavors.aks"]
+++
No changes are required. On clusters using `kix.flavors.eks`, `kix.flavors.gke`, `kix.flavors.gke-autopilot`, or `kix.flavors.aks`, you can now remove that cloud's identity domain from `scorecard.knownAnnotationDomains`. Each flavor now declares its cloud identity annotation domain (`eks.amazonaws.com` on `eks`, `iam.gke.io` on `gke` and `gke-autopilot`, and `azure.workload.identity` on `aks`), so `architecture.annotationDomainOwnership` accepts those annotations without a warning.
