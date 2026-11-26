+++
kind = "added"
packages = ["experimental/tempo", "cnpg-cluster"]
library = ["kix.cloudIdentity.use", "kix.cloudIdentity.gcp"]
state = true
id = "K2669"
+++
If a workload on GKE sets `hostNetwork: true` and uses a ServiceAccount with `kix.cloudIdentity.gcp`, give it a separate ServiceAccount without a cloud identity or remove `hostNetwork: true`. Evaluation now rejects this combination (`[K2669]`) because GKE does not grant Workload Identity to host-network pods and runs them as the node's service account. On AWS and Azure, if `kix deploy` fails a Deployment, StatefulSet, or DaemonSet with `CloudIdentityNotApplied`, fix the cluster's identity webhook or EKS Pod Identity association and restart the workload's pods. Kix now adds `kix.run/cloud-identity-env` to those workloads (without restarting pods) and checks during `kix deploy` that current-revision pods received the environment variables and values expected for IRSA, EKS Pod Identity, or Microsoft Entra Workload ID. With EKS Pod Identity, EKS does not expose the role ARN inside the pod, so `kix deploy` verifies that an association matched the ServiceAccount while you must ensure the AWS association names `roleArn`. `kix list resources` now lists every ServiceAccount with a cloud identity and its token subject (`cloudIdentities` in JSON output) for configuring cloud IAM trust policies and bindings. In addition, `kix.cloudIdentity.use` adds an optional `supportedClouds` list, and `tempo` and `cnpg-cluster` now report directly that they do not support Google Cloud or Azure identities yet.
