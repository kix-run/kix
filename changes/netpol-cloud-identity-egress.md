+++
kind = "fixed"
packages = ["cnpg-cluster", "experimental/stackgres-cluster", "experimental/velero"]
library = ["kix.cloudIdentity.annotationsFor"]
+++
No configuration changes are needed: redeploy clusters with `networkPolicy.enable = true` so workloads whose ServiceAccounts use a cloud identity can fetch cloud credentials. Previously, default-deny egress blocked those requests. Kix now adds credential egress rules automatically for workloads bound to a cloud identity (TCP 443 to external addresses for IRSA and Microsoft Entra Workload ID, TCP 80 to `169.254.170.23/32` and `fd00:ec2::23/128` for EKS Pod Identity, and TCP 80 and 8080 to `169.254.169.254/32` for GKE Workload Identity Federation). `cnpg-cluster`, `stackgres-cluster`, and `velero` also allow this traffic for their operator-created pods through the new `networkIntents` field returned by `kix.cloudIdentity.annotationsFor`; custom packages that call `annotationsFor` should pass `networkIntents` to `translateIntentRules` in their `kix.operandPolicy`. Workloads without a cloud identity are unchanged.
