+++
kind = "added"
packages = ["experimental/tempo", "cnpg-cluster"]
library = ["kix.cloudIdentity.use", "kix.cloudIdentity.gcp"]
state = true
id = "K2669"
+++
`kix deploy` now checks that the new pods of a Deployment, StatefulSet, or DaemonSet with a cloud identity actually received it. AWS and Azure webhooks add environment variables to a pod when they give it an identity, and Kix records the variables it expects in the workload's `kix.run/cloud-identity-env` annotation. If a pod is missing a variable or has a different value, the workload fails with `CloudIdentityNotApplied` and Kix suggests what to check. This catches an EKS Pod Identity association that overrides IRSA, Pod Identity mode with no association, or a webhook that did not run. With EKS Pod Identity, Kix cannot see which role an association names, so `roleArn` is the role the association must use, not a role Kix applies. `kix list resources` lists every ServiceAccount with a cloud identity and its subject (`cloudIdentities` in JSON), and the cloud identity reference page shows the subject in each cloud's own format. Kix now rejects a workload with `hostNetwork: true` whose ServiceAccount has a GKE identity (`[K2669]`), because GKE runs such pods as the node's service account. `tempo` and `cnpg-cluster` now say they do not support Google Cloud or Azure yet when given one of those identities, rather than suggesting a `config` change that does not exist.
