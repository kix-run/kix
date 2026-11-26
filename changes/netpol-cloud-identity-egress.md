+++
kind = "fixed"
packages = ["cnpg-cluster", "experimental/stackgres-cluster", "experimental/velero"]
library = ["kix.cloudIdentity.annotationsFor"]
+++
With `networkPolicy.enable = true`, a pod whose ServiceAccount has a cloud identity can now fetch its credentials. Before, default deny blocked the call, so the pod got no credentials. Kix now adds the traffic each cloud identity mechanism needs to that workload's egress policy: TCP 443 to any address outside the cluster for IRSA and Microsoft Entra Workload ID, TCP 80 to the EKS Pod Identity agent (`169.254.170.23` and `fd00:ec2::23`), and TCP 80 and 8080 to the GKE metadata server (`169.254.169.254`). `cnpg-cluster`, `stackgres-cluster`, and `velero` add it to the policies of the pods their operators create, through the new `networkIntents` field of `kix.cloudIdentity.annotationsFor`. Workloads without a cloud identity get no new rules. You do not need to change anything.
