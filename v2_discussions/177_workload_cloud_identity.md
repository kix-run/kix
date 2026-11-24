# 177: Workload cloud identity

**Status:** Draft. Phases 0 and 1 of the recommended design (D) are built in #330.
**Related:** `129_scaling_axes_fleet_and_linking.md` (names cloud identity as the first new role), `127_compiler_target_model.md`, `167_secrets_only_through_dependencies.md`, `103_permissioned_identity.md`, `archive/128_capability_ownership_decomposition.md`

## 1. The request

A team evaluating Kix on EKS asked whether there is "an IRSA helper for
packages". The external-dns guide tells the reader to type the
`eks.amazonaws.com/role-arn` annotation into a package option and then
silence a scorecard warning, because Kix does not know who reads it. The
brief for this doc is wider: design "this workload acts as that cloud
identity" for most users on the common platforms, and say how far one
concept stretches.

## 2. The mechanisms (checked against vendor docs on 2026-11-24)

| Mechanism | What sits in the cluster | What sits outside | The pod talks to |
|---|---|---|---|
| EKS, IAM Roles for Service Accounts (IRSA) | ServiceAccount annotation `eks.amazonaws.com/role-arn`. Optional `audience`, `sts-regional-endpoints`, `token-expiration`. A webhook adds a projected token and `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` to new pods. | An IAM OIDC provider for the cluster. A role whose trust policy names `system:serviceaccount:<ns>:<sa>`. | STS on 443 (regional endpoint, or a VPC endpoint) |
| EKS Pod Identity | Nothing. AWS: "you don't add any annotations". EKS injects `AWS_CONTAINER_CREDENTIALS_FULL_URI` into new pods. | An association (cluster, namespace, ServiceAccount, role) made through the EKS API. The agent add-on on every node (built into Auto Mode). | The node agent at `169.254.170.23:80` |
| GKE, direct access (Google's default form) | Nothing | An IAM binding on `principal://…/subject/ns/<ns>/sa/<sa>` | The metadata server: `169.254.169.252:988`, and `169.254.169.254:80` on Dataplane V2 |
| GKE, linked service account | ServiceAccount annotation `iam.gke.io/gcp-service-account` | A Google service account and a `workloadIdentityUser` binding. Google asks for both. | Same |
| AKS, Entra Workload ID | ServiceAccount annotation `azure.workload.identity/client-id` (optional `tenant-id`). Pod label `azure.workload.identity/use: "true"`, required. A webhook adds `AZURE_*` variables and a projected token. | A federated credential with subject `system:serviceaccount:<ns>:<sa>` | `login.microsoftonline.com` |
| Self-managed cluster, IRSA webhook | The IRSA annotation. The prefix is a webhook flag. The webhook is a Deployment the cluster owner installs. | A public OIDC discovery document, API server flags, an IAM OIDC provider | STS on 443 |
| Self-managed cluster, no webhook | A projected ServiceAccount token volume with a custom audience, plus two environment variables (AWS) or a credential ConfigMap and `GOOGLE_APPLICATION_CREDENTIALS` (Google) | The same federation setup | STS or `sts.googleapis.com` on 443 |

AWS now says: "AWS recommends using EKS Pod Identities to grant access to
AWS resources to your pods whenever possible." IRSA remains the answer on
Fargate, Windows nodes, EKS Anywhere, OpenShift on AWS, and self-managed
clusters. For a compiler that emits Kubernetes objects, the recommended AWS
form and the default Google form leave nothing to emit. The only Kubernetes
object for a Pod Identity association is a custom resource of an AWS
controller the cluster may not run: `PodIdentityAssociation` in
`eks.services.k8s.aws/v1alpha1` (ACK) or `eks.aws.upbound.io/v1beta1`
(Crossplane). Azure's newer "identity bindings" move the authorization into
a ClusterRole and ClusterRoleBinding.

Two facts hold for every row:

- **The subject is always the pair (namespace, ServiceAccount name).** Kix
  computes both. The cloud side must name the same pair.
- **Credentials reach a pod only when it starts.** AWS: the webhook
  "doesn't apply them to Pods that are already running". A changed identity
  needs new pods, and a pod created before the webhook is up gets nothing.

The rows differ in the value (an ARN, an email address, a client ID, or
nothing), in where the declaration lands (the ServiceAccount, the pod, a
separate object, or the cloud alone), and in the address the pod reaches.

**Where the analogy stops.** Vault and OpenBao bind a role to a
ServiceAccount on the server, but the client names the role: the injector's
pod annotation, the `VaultAuth` resource, or an External Secrets
`SecretStore`. The ServiceAccount carries nothing, so this belongs to the
package that runs the client. SPIFFE assigns identities by `ClusterSPIFFEID`
selectors and delivers them through a CSI socket. This doc leaves both out.

## 3. What upstream software needs

A survey of 21 projects (sources in section 12) found:

- About 16 attach the identity to their own ServiceAccount: external-dns,
  cert-manager, Velero, Loki, Tempo, Mimir, Harbor's registry, Karpenter,
  the AWS Load Balancer Controller, the CSI drivers, cluster-autoscaler,
  Thanos. Two CSI drivers have two ServiceAccounts.
- Five attach it to a ServiceAccount that an operator creates or that a
  custom resource names: CloudNativePG (`serviceAccountTemplate` on the
  Cluster), StackGres, VictoriaMetrics (the backup sidecar in the vmstorage
  pods of a VMCluster), Argo Workflows, and
  the recommended mode of External Secrets.
- Nearly every storage user also needs an application switch that differs
  per cloud: `inheritFromIAMRole`, `gkeEnvironment`, `useIAMRole`,
  `use_federated_token`, `useSDKCreds`, `aws_sdk_auth`, Velero's `useAAD`.
- Nine document EKS Pod Identity. The others are silent, and it may work
  through the SDK's credential chain.

So an identity declaration is never the whole job. A package still maps
"credentials are ambient" onto its own configuration, and the instance's
config already names the cloud (`provider = "aws"`, an S3 block).

## 4. Kix today

- 52 packages build a ServiceAccount. Two have a `serviceAccountAnnotations`
  option: `experimental/external-dns` and `stable/victoria-metrics-operator`
  (no description). The operator pod calls no cloud API, so its option is a
  general pass-through and not a cloud credential setting. Velero and `stackgres-object-storage` list cloud
  identity under known limits and point at `partsOverlays` and `extraSpec`.
- `architecture.annotationDomainOwnership` (`kix/lib/rules/architecture.nix`)
  warns when an annotation's domain is not reserved, not in
  `scorecard.knownAnnotationDomains`, and not declared by a package through
  `meta.annotationDomains`. No flavor registers its cloud's domain, and
  `kix.mkImport` cannot declare one, so the environment has no way to say
  "I read this annotation". That is the warning the evaluator saw.
- Roles (`kix/lib/eval/roles.nix`) already model "the environment or a
  package provides this": a registry entry, a binding mode per flavor, and
  an `out` contract. `scope.networkPolicyEnforcer` hands a package the
  resolved provider. Doc 129 named cloud identity as the next role.
- Generated network policy runs only when an instance claims
  `network-policy-enforcer`, and only Cilium does. The `eks`, `gke`, and
  `aks` flavors bind `cni` as exclusive, so on a stock managed cluster Kix
  writes no policy and nothing blocks the token exchange. On a Cilium
  cluster, external-dns already allows the world on TCP 443, which covers
  STS and Entra. Nothing allows the EKS node agent or the GKE metadata
  server.
- `meta.network.intents` cannot read config, so a package cannot open an
  egress rule only when an identity is set.
- The pod spec already accepts `serviceAccount = self.serviceAccount`, and
  the builder (`_expandServiceAccount` in `kix/lib/scope/builders.nix`)
  turns it into `serviceAccountName`. The workload builder therefore holds
  the ServiceAccount object when it builds the pod template.
- `instances.<ns>.<name>.availability` is an instance-level attribute whose
  result Kix hands to the package. A cloud identity can follow that shape.

## 5. The concept and its boundary

**A cloud identity is a statement by the cluster author that one
ServiceAccount of one instance acts as one named principal in one cloud.**

| Who | Declares | Never declares |
|---|---|---|
| Package | Which ServiceAccount talks to the cloud. What changes in its own configuration when credentials are ambient. | A role, an account, or a cloud |
| Cluster author | The principal, in that cloud's own terms (role ARN, Google service account or none, client ID) | Annotation keys, labels, volumes |
| Platform (a flavor, an import, or a webhook package) | How this cluster delivers the identity | Any principal |

Kix creates no cloud objects. It emits the Kubernetes side and states what
it expects to exist.

| | What Kix can do |
|---|---|
| At build | Refuse an identity on a cluster with no provider. Refuse a value for the wrong cloud, or a malformed ARN, email, or client ID. Refuse an identity that no ServiceAccount binds. Refuse a package that has neither an identity nor a credentials Secret, or both. Warn about a `hostNetwork` pod on GKE, which Google excludes. Order the webhook before its consumers when the webhook is a Kix instance. |
| At deploy (later phase) | Check that the new pod carries the injected variables (`AWS_ROLE_ARN`, `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AZURE_CLIENT_ID`). That proves the webhook or agent acted, without any cloud call. |
| Out of reach | The role's trust policy and permissions, the OIDC provider registration, the Pod Identity association, the GKE IAM binding, the Azure federated credential. Kix can print the exact subject each one must name. |

## 6. The designs

The sketches use external-dns on EKS with IRSA.

### A. Shared option and a known-domain registry

Each flavor registers its cloud's annotation domain, and every package gains
one shared ServiceAccount option:

```nix
instances.dns.external-dns.config.serviceAccount.annotations."eks.amazonaws.com/role-arn" =
  "arn:aws:iam::111122223333:role/external-dns";
```

Every field is a standard Kubernetes field. It prevents no mistake: a
mistyped key, a missing Azure pod label, and a pod that never restarts all
pass, Pod Identity and GKE direct access leave Kix knowing nothing, and fifty
packages need the option.

### B. A cloud-neutral string on the ServiceAccount

One string cannot hold Azure's client and tenant, or GKE's "no value", and
the compiler would branch on `cluster.provider`, which `modules.nix` forbids.

### D. The identity is the credentials dependency (recommended)

The mechanism comes from the flavor through a `cloudIdentity` role. The value
comes through `deps`, where a package already receives its credentials
Secret. `deps.<name>` already accepts a plain value, so no second instance is
needed. The identity and the Secret fallback differ in one right-hand side:

```nix
# cluster, EKS
imports = [ kix.flavors.eks ];
instances.dns.external-dns = {
  package = packages.experimental.external-dns;
  deps.providerCredentials = kix.cloudIdentity.aws {
    roleArn = "arn:aws:iam::111122223333:role/external-dns";
  };
  # or the Secret: deps.providerCredentials = ref.dns.aws-keys;
  config.provider = "aws";
};

# GKE (direct access, or a linked service account), and AKS
deps.providerCredentials = kix.cloudIdentity.gcp { };
deps.providerCredentials = kix.cloudIdentity.gcp { serviceAccount = "dns@project.iam.gserviceaccount.com"; };
deps.providerCredentials = kix.cloudIdentity.azure { clientId = "00000000-0000-0000-0000-000000000000"; };

# self-managed cluster: the mechanism is chosen with the cluster, beside
# the flavor, the way the cloud flavors carry theirs
modules = [
  kix.flavors.kubeadm
  kix.modules.experimental.irsa-webhook
  { irsaWebhook.annotationPrefix = "irsa.example.com"; }   # only for another prefix
];
```

```nix
# package
build = { self, config, providerCredentials ? null, ... }:
  let
    credentials = kix.cloudIdentity.use {
      inherit scope;
      dep = providerCredentials;          # an identity, a Secret instance, or null
      cloud = "aws";                      # the cloud its software calls
    };
  in {
    serviceAccount =
      { apiVersion = "v1"; kind = "ServiceAccount"; inherit name; }
      |> credentials.bind
      |> scope.mkResource;
    # envFrom credentials.secret when it is not null
  };
```

The constructors (`aws`, `gcp`, `azure`) check their fields, so a mistyped
key names the field. `scope.mkResource` renders a bound identity through the
mechanism of the role's provider, which `findRoleProvider` reaches without
the package naming it, adds the provider's root as a dependency, and the
workload builders stamp the pods.

Two layers stay apart in what a user reads. `kix.cloudIdentity` holds only
the role a workload gets (`aws`, `gcp`, `azure`) and what a package reads
(`use`, `annotationsFor`). How the cluster delivers it is chosen with the
cluster: the `eks`, `gke`, `gke-autopilot`, and `aks` flavors carry it, and a
self-managed cluster adds a module (`irsa-webhook`,
`azure-workload-identity-webhook`). The mechanism records (IRSA, EKS Pod
Identity, GKE, Entra Workload ID) are library internals; a Kix package for a
self-hosted webhook would claim the role and take precedence.

A workload definition can stay free of credentials: a module shared by
several cluster files sets the software's own settings, and each cluster
file gives `deps.providerCredentials` its value, a role on EKS and a Secret
`ref` on kind (`clusters/test-cloud-identity-layout/` in #330). `cloud` stays because it catches a
real mistake that the cluster's mechanism cannot: external-dns writing to
Cloud DNS from an EKS cluster with an AWS identity.

**Against "don't invent new fields".** D adds no instance key and no
manifest field. The value uses each cloud's nouns. Like a Secret instance,
it is a dependency that the environment renders into standard fields.

### C. A typed identity on the instance (rejected after it was built)

C put the value in a new instance attribute, `cloudIdentity.aws.roleArn`,
and handed it to the package as `scope.cloudIdentity`; a helper,
`orSecret`, refused an instance with both an identity and a Secret, and
`eval/instance.nix` gained two checks: no provider, and a package that
bound nothing. It renders the same annotations, label, and stamp as D, and
was built first. It lost because:

- `cloudIdentity` on an instance and `scope.cloudIdentity` are library
  surface that could only be removed in a minor release, and a new instance
  key is the kind of invented field the DSL avoids.
- D gets three checks from machinery that exists. "Both" cannot be
  written. "The package has not adopted it" is the existing refusal of a
  dependency the package does not take (`[K3646]`). "Neither" is a missing
  dependency, which a package asserts where some modes need none.
- C gives one identity per instance; D gives a package with two
  ServiceAccounts two dependencies.

C kept one thing D loses: a paste-in overlay that binds the identity for a
package that has not adopted it. Under D such a package takes the raw
annotation through `partsOverlays`, which the scorecard now accepts, but its
pods do not restart when the role changes.

### The cases

| Case | A | D |
|---|---|---|
| EKS IRSA | Works. The author types the key. | Annotation, restart stamp |
| EKS Pod Identity | Nothing to write. No record. | No annotation. The record and the stamp. |
| GKE direct / linked | Nothing, or the annotation | The record, or the annotation, and the stamp |
| AKS | Needs a second option for the pod label | Annotation and pod label |
| Self-managed, webhook | Domain registered by hand | A module beside the flavor |
| Self-managed, no webhook | Not covered | A later mechanism adds the token volume |
| Secret fallback | No check | The same dependency, a `ref` |

### Also considered

- **A second instance per identity**, like `secret-ref`. It works, and an
  earlier draft of this doc dismissed the dependency shape for the wrong
  reason: it assumed the identity had to be an instance, and that the
  consumer would then render everything. A plain value in `deps` needs no
  instance, and the consumer renders nothing: `bind` and the builders do.
  An instance buys nothing, because its subject is one ServiceAccount and it
  cannot be shared.
- **A table on the flavor** (`cluster.cloudIdentity."ns/name".aws...`). It
  is C with the value moved away from the instance, and needs a check that
  each key names an instance.
- **Apply the identity to an instance's only ServiceAccount with no package
  change.** A resource is sealed when it is built, so nothing outside the
  package can patch it.
- **A cloud-neutral name mapped to a role by a naming rule.** It hides the
  one value a reviewer must see.

## 7. What rides on the declaration

| Concern | What D does |
|---|---|
| Scorecard | The flavor's import declares the annotation domain (`kix.mkImport` `annotationDomains`), so the warning goes away with no per-cluster setting. |
| Egress | Later: the mechanism's rules join the workload's generated policy when an enforcer exists. Whether Cilium default-deny blocks `169.254.170.23` needs a test on a real cluster. |
| Identity or Secret | One dependency holds either. A package asserts "neither" only for the modes that need credentials. |
| Restart | The workload builder stamps `checksum/cloud-identity` on every pod template that names a bound ServiceAccount, because the interceptor hook's `podSpec` channel reaches `spec.template.spec` only. |
| `kix diff` | The annotation, the label, and the stamp show as ordinary changes; the ServiceAccount also carries `kix.run/cloud-identity`. |
| Ordering | The bound ServiceAccount depends on the role provider's root. |
| What must exist outside | Later: the subject of each identity as JSON for a Terraform module. |

## 8. Migration and change kinds

| Step | Change | Record |
|---|---|---|
| Flavors declare their cloud's annotation domain | A warning stops. | `fixed` |
| Role, constructors, `use`, flavor imports, webhook modules | New surface. The flavor's import adds a marker object to existing EKS, GKE, and AKS clusters. | `added`, plus a `note` |
| A package's `assertions` see plain `deps` values | They did not before. | `changed` |
| external-dns takes an identity in `providerCredentials` and drops `serviceAccountAnnotations` | Experimental. The old option is refused with an error naming the new line. A cloud provider with no credentials is refused. | two `error` records |
| Velero, cert-manager, Tempo, Harbor, external-secrets, cnpg-cluster, stackgres-object-storage | Additive in each package | `added` each |

Two packages are not on this list. The VictoriaMetrics operator pod calls no
cloud API, so its `serviceAccountAnnotations` option is a general
pass-through and stays. The pod that does call one is the backup sidecar in
the vmstorage pods of `victoria-metrics-cluster`, which can take a cloud
identity when a user asks for it. Kix's `loki` package keeps its data on a
volume and calls no cloud API, so it takes a cloud identity once it has an
object store.

## 9. Recommendation and plan

Build D. **Phase 0** (the domain declarations) and **phase 1** (the role,
constructors, `use`, the mechanisms for EKS, GKE, and AKS, the
self-managed webhook modules, and external-dns) are built in #330. **Phase 2**, one pull request per package:
the packages in section 8, with their per-cloud application switch, the
operator path (`kix.cloudIdentity.annotationsFor`), and egress. **Phase 3**,
on demand: a per-instance mechanism on EKS, the ACK Pod Identity object,
`projectedToken`, the deploy-time check of injected variables, and the JSON
list of subjects.

## 10. Should we build this now

**Who benefits today.** Anyone on EKS, GKE, or AKS who installs
external-dns, Velero, cert-manager with DNS01, or a backup to object
storage, and anyone whose own application reads a bucket. That is most
cloud users. Against that: doc 129 calls most cloud flavors guesses, and
the evaluator is the first recorded request.

**What it costs.** Phase 0 is a few lines. Phase 1 is about a week with
tests and docs, and adds a role, three value constructors, and one package
helper (`use`) that every later package review must know.

**The cheapest step that removes the complaint** is phase 0: the warning
goes, and the guide stops telling a new user to silence the scorecard. The
inconsistency between packages stays until phase 1.

Recommendation: do phase 0 now. Do phase 1 next if EKS, GKE, or AKS users
are a near-term target, because the per-package option would otherwise
spread, and each copy is a breaking removal later. Hold phases 2 and 3
until a user asks for a package or for Pod Identity.

## 11. Decisions for the maintainer

1. **Build the full design or only the small fix?** The small fix teaches
   the EKS, GKE, and AKS presets that the cloud reads its own annotations,
   so the warning stops. Users still type the raw annotation into a
   per-package option. The full design lets a package's credentials
   dependency hold the cloud role in place of a Secret, and Kix writes the
   annotation, the Azure pod label, and a pod restart when the role
   changes. *Recommended and built: both.*
2. **Should the setting use each cloud's own words, or one neutral name?**
   With cloud words, the cluster author writes an AWS role ARN on AWS and a
   client ID on Azure, and a cluster that changes cloud edits the setting.
   With a neutral name, Kix would map a name such as `dns-writer` to a role
   through a naming rule the author sets once. Applications already need
   cloud-specific settings beside it, so the neutral name saves little and
   hides the value a reviewer wants to see. *Recommended: each cloud's own
   words.*
3. **On EKS, which AWS mechanism should Kix assume when the author says
   nothing?** The older mechanism puts the role on the ServiceAccount as an
   annotation, works everywhere, and is fully visible in what Kix emits.
   The newer one, which AWS now recommends, keeps the link in the AWS API,
   so Kix emits nothing and can only record what it expects. *Recommended:
   assume the older mechanism, and let the author switch the cluster or one
   instance to the newer one.*
4. **For the newer AWS mechanism, should Kix ever write the link itself?**
   It can only do so as a custom resource of an AWS controller running in
   the cluster (ACK or Crossplane), which most clusters do not have.
   Otherwise the link is made by Terraform or by hand, and Kix prints the
   namespace and ServiceAccount name to use. *Recommended: print only, and
   add the custom resource when a user who runs that controller asks.*
5. **Should an identity given to a package that has not adopted cloud
   identity fail the build?** It does, with the existing error for a
   dependency the package does not take. Such a package can still get the
   raw annotation through an overlay, without the restart.
   *Recommended: keep it.*
6. **Remove the two existing annotation options?** external-dns is
   experimental, so its option can go in any release with an error naming
   the new setting. The VictoriaMetrics operator's option is not for cloud
   credentials, because the operator pod calls no cloud API. *Recommended:
   remove the external-dns one when it adopts the new setting. Keep the
   VictoriaMetrics operator's option.*
7. **Should Kix record the declared role on the ServiceAccount under its
   own annotation?** For the two mechanisms that put nothing in the cluster,
   this is the only way a preview shows that a role changed, and the only
   place another tool can read what Kix expects. It is one more Kix
   annotation on an object. *Recommended: yes.*
8. **Leave Vault, OpenBao, and SPIFFE out?** They also tie an identity to a
   ServiceAccount, but the role is named in the client's configuration or
   by a rule on the server, so Kix has nothing to put on the workload.
   *Recommended: leave them out and name the feature for clouds.*

Open details: one identity per instance or per bound ServiceAccount (two
CSI drivers have two); a per-instance mechanism on EKS; the extra IRSA
annotations, which can stay raw annotations in the first version.

## 12. Sources confirmed on 2026-11-24

- **IRSA:** `github.com/aws/amazon-eks-pod-identity-webhook` (README, `SELF_HOSTED_SETUP.md`); EKS user guide `pod-configuration.html`, `configure-sts-endpoint.html`.
- **EKS Pod Identity:** EKS user guide `pod-identities.html`, `pod-id-association.html`, `pod-id-how-it-works.html`, `pod-id-agent-setup.html`, `service-accounts.html` (the recommendation); the `CreatePodIdentityAssociation` API reference; the ACK and Upbound references for `PodIdentityAssociation`.
- **GKE:** `docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity` and `concepts/workload-identity`; `iam/docs/workload-identity-federation-with-kubernetes`.
- **AKS:** `learn.microsoft.com/azure/aks/workload-identity-overview` and `identity-bindings-concepts`; `azure.github.io/azure-workload-identity`.
- **Others:** Vault and OpenBao Kubernetes auth docs; `spiffe/spire-controller-manager` `ClusterSPIFFEID`; Kubernetes projected volumes.
- **Survey:** each project's own docs or chart README, read the same day.

Not confirmed: whether a default-deny Cilium policy blocks the EKS node
agent address; the port for Entra (HTTPS is implied); the general
availability of AKS identity bindings; Pod Identity support in the projects
whose docs are silent.
