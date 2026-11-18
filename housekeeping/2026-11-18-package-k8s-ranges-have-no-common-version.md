# 2026-11-18 · `kix/lib/meta.nix` · No Kubernetes version satisfies every package's `meta.k8s` range, so some pairs of packages cannot share a cluster that sets `k8sVersion`.

The authoring skill now tells a version bump to encode upstream's stated Kubernetes support in `meta.k8s`, and `checkMetaStatic` turns a version outside that range into a build failure. Upstream projects state support in different ways, and the ranges no longer overlap:

| Package | Range | Upstream's statement |
|---|---|---|
| `kube-state-metrics` 2.20.0 | 1.36 only | the Kubernetes version of the client-go it builds with |
| `external-secrets` | 1.37 only | the support table in its `stability-support.md` |
| `keycloak` 26.8.2 | 1.31 to 1.34 | "OpenShift 4.18-4.21, corresponding to Kubernetes API 1.31-1.34" |
| `infisical-operator` | 1.29 to 1.33 | the supported-versions list on its Kubernetes page |

A cluster that runs `kube-state-metrics` and `keycloak` fails on every `k8sVersion`. So does one that runs `kube-state-metrics` and `external-secrets`. A cluster that runs only `kube-state-metrics`, which is any cluster with monitoring, must run exactly Kubernetes 1.36, and the next `kube-state-metrics` bump moves that to exactly 1.37. Its users would have to upgrade Kubernetes and Kix in the same step.

The only way out today is to remove `k8sVersion` from the cluster, which turns off every range check and the deploy-time version check with it.

The cause is that one range carries two different facts. "Upstream does not state support for this version" and "the package does not work on this version" are both a refusal. Most of the ranges above are the first kind. Keycloak makes no Kubernetes API call that 1.35 or 1.36 changes. kube-state-metrics 2.20.0 has one known break below 1.36: its `mutatingadmissionpolicies` and `mutatingadmissionpolicybindings` collectors, on by default, read `admissionregistration.k8s.io/v1`, and Kubernetes 1.34 and 1.35 serve those kinds only as `v1beta1`. Its README recommends the latest release for older clusters and calls other versions "best effort". I did not test 2.20.0 on an older cluster.

Options:

1. Give `meta.k8s` two ranges. A hard range refuses, and holds only versions where the package is known to fail, such as an API version the cluster does not serve. A supported range holds upstream's statement and produces a warning, which a scorecard rule can raise to an error for clusters that want it. Cost: a library change, a pass over every range to sort its bounds into the two kinds, and updates to the authoring skill and `package-anatomy.mdx`.
2. Keep one range and let an instance name a Kubernetes version it accepts outside it. The refusal names the setting. Cost: a smaller library change, but the default is still a refusal, so every cluster with monitoring carries an acceptance and updates it at each bump.
3. Fix the two packages. `kube-state-metrics` leaves the two collectors out of `--resources` below 1.36 and widens its range, and `keycloak` drops its upper bound. Cost: both contradict the skill's rule that upstream's stated support wins, the same conflict returns with the next package, and `kube-state-metrics` needs `k8sVersion` in `build`, which `2026-11-18-meta-k8s-cannot-scope-range-to-option.md` already asks about.

I recommend option 1. It keeps upstream's statement visible and stops it from blocking a build that works.

Decision required from Adam, before 0.10.0 if clusters are to set `k8sVersion` with these packages.
