# 177: Workload cloud identity

**Status:** Draft (RFC with a recommended design and a phased plan)
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
  Cluster), StackGres, the VictoriaMetrics operator, Argo Workflows, and
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
  (no description). Velero and `stackgres-object-storage` list cloud
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

## 6. Three designs

The sketches use external-dns on EKS with IRSA.

### A. Shared option and a known-domain registry

Each flavor registers its cloud's annotation domain. `kix.options` gains
one shared ServiceAccount option that every package adopts.

```nix
# package
options.serviceAccount = kix.options.serviceAccount;   # { annotations; podLabels; }
serviceAccount = scope.mkResource ({
  apiVersion = "v1"; kind = "ServiceAccount"; inherit name;
} // lib.optionalAttrs (config.serviceAccount.annotations != { }) {
  inherit (config.serviceAccount) annotations;
});

# cluster
instances.dns.external-dns.config.serviceAccount.annotations."eks.amazonaws.com/role-arn" =
  "arn:aws:iam::111122223333:role/external-dns";
```

Every field is a standard Kubernetes field, the strongest reading of "don't
invent new fields". It prevents no mistake: a mistyped key, a missing Azure
pod label, and a pod that never restarts all pass. Pod Identity and GKE
direct access leave Kix knowing nothing. Fifty packages need the option.

### B. A cloud-neutral value on the ServiceAccount

The package passes an opaque string to a ServiceAccount builder, and the
flavor decides what it means.

```nix
# package
options.cloudIdentity = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
serviceAccount = scope.mkServiceAccount { inherit name; cloudIdentity = config.cloudIdentity; };

# cluster
instances.dns.external-dns.config.cloudIdentity = "arn:aws:iam::111122223333:role/external-dns";
```

One string cannot hold Azure's client and tenant, or GKE's "no value". The
compiler would branch on `cluster.provider`, which `modules.nix` forbids.
The option is still per package, and the neutral value buys no portability
(section 3).

### C. A typed identity on the instance, rendered by a role provider (recommended)

The cluster author sets one attribute on the instance, in the cloud's own
words. A `cloudIdentity` role resolves to the provider that renders it. The
package binds it to a ServiceAccount with one call and never sees the cloud.

```nix
# package: own ServiceAccount (16 of 21 surveyed projects)
serviceAccount =
  { apiVersion = "v1"; kind = "ServiceAccount"; inherit name; }
  |> scope.cloudIdentity.bind
  |> scope.mkResource;

# package: refuse "neither" and "both"
_credentials = kix.cloudIdentity.orSecret {
  identity = scope.cloudIdentity;
  secret = deps.providerCredentials or null;
  what = "the ${config.provider} provider";
};

# package: ServiceAccount made by an operator (CloudNativePG)
spec.serviceAccountTemplate.metadata.annotations = scope.cloudIdentity.serviceAccountAnnotations;
spec.inheritFromIAMRole = scope.cloudIdentity.cloud == "aws";
```

```nix
# cluster, EKS
imports = [ kix.flavors.eks ];
instances.dns.external-dns = {
  package = packages.experimental.external-dns;
  config.provider = "aws";
  cloudIdentity.aws.roleArn = "arn:aws:iam::111122223333:role/external-dns";
};

# GKE (direct access, or a linked service account), and AKS
cloudIdentity.gcp = { };
cloudIdentity.gcp.serviceAccount = "dns@project.iam.gserviceaccount.com";
cloudIdentity.azure.clientId = "00000000-0000-0000-0000-000000000000";

# self-managed cluster: the cluster author states the mechanism once
instances.kube-system.cloud-identity.package = kix.mkImport {
  roles = [ "cloudIdentity" ];
  out.cloudIdentity = kix.cloudIdentity.irsa { };          # or .projectedToken { audience = "sts.amazonaws.com"; }
};
```

A provider's `out.cloudIdentity` is a small record: the cloud it accepts
and a `render` function from the value and the subject to ServiceAccount
annotations, pod labels, pod spec additions, extra resources, egress rules,
and the sentence that says what must exist outside. Kix ships the
constructors (`irsa`, `eksPodIdentity`, `gke`, `azureWorkloadId`,
`projectedToken`). The `eks`, `gke`, and `aks` flavors place a default
import, the way they place `platform-dns`. A Kix package for a self-hosted
webhook claims the role and takes precedence, which also orders it before
its consumers.

The attribute is `cloudIdentity` because "identity" already means the
content hash in Kix ("identity hash", "workload identity" in `builders.nix`).

**Against "don't invent new fields".** C invents one instance attribute and
no manifest field. The value uses each cloud's nouns, so nothing is
translated. Like `availability` and `kix.expose`, it is an intent that the
environment renders into standard fields. It passes "automation over
brevity" because each part prevents a named mistake (section 7), and
"resources are rich objects" because the workload builder reads
`out.cloudIdentity` from the ServiceAccount in the pod spec.

### The cases

| Case | A | B | C |
|---|---|---|---|
| EKS IRSA | Works. The author types the key. | Works | Annotation, restart stamp, STS egress |
| EKS Pod Identity | Nothing to write. No record. | Renders nothing. No record. | No annotation. Restart stamp, egress to the node agent, the subject printed, and optionally the ACK object. |
| GKE direct | Same as above | Cannot say "no value" | Same as above with the metadata server |
| GKE linked | Works | Works | Annotation |
| AKS | Needs a second option for the pod label | Works | Annotation and pod label |
| Self-managed, webhook | Works. The domain is registered by hand. | No provider to pick | The webhook package or an import is the provider |
| Self-managed, no webhook | Not covered | Not covered | The provider adds the token volume and variables |
| No identity, Secret fallback | No check | No check | `orSecret` refuses neither and both. An identity on a cluster with no provider is an error. |

### Also considered

- **Identity as a dependency instance**, like the secret contract of doc
  167. A dependency cannot read its consumer's ServiceAccount name, so the
  consumer would still render everything, and each workload would need two
  instances.
- **Apply the identity to an instance's only ServiceAccount with no package
  change.** A resource is sealed when it is built, before Kix can count the
  instance's ServiceAccounts, and the operator-made ServiceAccounts of
  section 3 need the package to place the value anyway.
- **A cloud-neutral name mapped to a role by a naming rule.** It hides the
  one value a reviewer must see, and the clouds share no naming scheme.

## 7. What rides on the declaration

| Concern | What C does |
|---|---|
| Scorecard | The flavor or the webhook package owns the annotation domain, so the ownership warning goes away with no per-cluster setting. |
| Egress | The provider's rules join the workload's generated policy when an enforcer exists: TCP 443 to the world for IRSA and Azure, the node agent for Pod Identity, the metadata server for GKE. Cilium treats a node-local address as the `host` entity; whether default-deny blocks `169.254.170.23` was not confirmed and needs a test on a real cluster. |
| Identity or Secret | `kix.cloudIdentity.orSecret` in the package. The package review checklist asks for it in every package whose software calls a cloud API. |
| Restart | The workload builder stamps `checksum/cloud-identity` on the pod template of every workload that runs as a bound ServiceAccount. A changed principal or mechanism rolls the pods. The stamp and the Azure pod label go in through the builder, because the interceptor hook's `podSpec` channel reaches `spec.template.spec` only. |
| `kix diff` | The annotation, the label, and the stamp show as ordinary changes. For the mechanisms that emit nothing, the stamp is the only trace, so the ServiceAccount also carries `kix.run/cloud-identity` with the declared value. |
| Ordering | A webhook that is a Kix instance becomes a dependency of every bound workload. |
| What must exist outside | A build error or `kix` listing prints the subject for each instance: `system:serviceaccount:dns:external-dns` and the role. A later phase can write the list as JSON for a Terraform module to read. |

## 8. Migration and change kinds

| Step | Change | Record |
|---|---|---|
| Flavors register their cloud's annotation domain | A warning stops. No manifest changes. | `fixed` |
| Role, instance attribute, `scope.cloudIdentity`, constructors | New surface. The flavor's import adds a marker object to existing EKS, GKE, and AKS clusters, so the change-kind check will list changed manifests. | `added`, plus a `note` for the marker |
| external-dns adopts it and drops `serviceAccountAnnotations` | Experimental package. The old option is refused with an error that names `cloudIdentity` and the record id. A user who moves over gets the same annotation plus the restart stamp, which rolls the pods once; the record says so. | `error`, listed under experimental breaks; a patch release may carry it |
| victoria-metrics-operator | Stable package. Removing its option is an `error` record in a minor release (0.11). The option is generic and undocumented, so it could also stay. | `error` in 0.11, or none |
| Velero, cert-manager, Loki, Tempo, Harbor, external-secrets, cnpg-cluster, stackgres-object-storage adopt it | Additive in each package | `added` each |

## 9. Recommendation and plan

Build C, in four phases. Phase 0 stands alone and removes the complaint.

**Phase 0, half a day.** `kix/lib/flavors/eks.nix`, `gke.nix`,
`gke-autopilot.nix`, and `aks.nix` add their cloud's domain to
`scorecard.knownAnnotationDomains` (a list option, so a cluster's entries
still merge). One unit test per flavor. Rewrite "Use workload identity" in
the external-dns guide, and update `reference/flavors-and-capabilities.mdx`
and `reference/cluster-configuration.mdx`. Record: `fixed`.

**Phase 1, about 500 lines of library, 300 of tests, two or three pull
requests.** The first useful slice is IRSA on external-dns.

- `kix/lib/eval/roles.nix`: role `cloudIdentity`, contract `[ "cloudIdentity" ]`.
- `kix/lib/vocab/cloud-identity.nix`: value validation, the `irsa`, `gke`,
  and `azureWorkloadId` constructors, `orSecret`.
- `kix/lib/modules.nix`, `kix/lib/eval/instance.nix`, `kix/lib/scope/`: the
  instance attribute and `scope.cloudIdentity` (`bind`, `isSet`, `cloud`,
  `serviceAccountAnnotations`, `podLabels`).
- `kix/lib/scope/builders.nix`: the pod label, the stamp, and the provider
  dependency, read from the bound ServiceAccount.
- Flavor imports for `eks`, `gke`, `gke-autopilot`, `aks`. external-dns
  adopts it. `kix/lib/architecture.md` gains the role.
- Tests in `kix/lib/tests/units/`: each provider's rendering, no provider,
  wrong cloud, unbound identity, `orSecret`, the restart stamp.
- Docs: `instances-and-composition.mdx`, `flavors-and-capabilities.mdx`,
  `composition-helpers.mdx`, `resources-and-out.mdx`, a new how-to "Give a
  workload a cloud identity", and the docs ledger. Skills:
  `package-authoring` (a pattern row), `package-review` (two checklist
  items), `kix-migration`. `ROADMAP.md`. Run the copy pass.

**Phase 2, one small pull request per package.** The packages in section 8,
with the per-cloud application switch each one needs. Add the egress rules
through a workload interceptor.

**Phase 3, on demand.** `eksPodIdentity` with the optional ACK object and
`projectedToken`. The deploy-time check of injected variables. The JSON
list of subjects. A package for the self-hosted AWS or Azure webhook.

## 10. Should we build this now

**Who benefits today.** Anyone on EKS, GKE, or AKS who installs
external-dns, Velero, cert-manager with DNS01, or a backup to object
storage, and anyone whose own application reads a bucket. That is most
cloud users. Against that: doc 129 calls most cloud flavors guesses, and
the evaluator is the first recorded request.

**What it costs.** Phase 0 is a few lines. Phase 1 is about a week with
tests and docs, and adds a role, an instance attribute, and a scope handle
that every later package review must know.

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
   per-package option. The full design gives every instance one setting for
   its cloud role, and Kix writes the annotation, the Azure pod label, and
   a pod restart when the role changes. *Recommended: the small fix now,
   the full design next.*
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
5. **Should an instance that is given a cloud role fail the build when its
   package has not been taught about cloud roles?** Failing is safe: the
   author learns at once that nothing would happen. It also means a package
   Kix has not updated cannot use the feature except through the existing
   escape hatch that edits a package's objects. *Recommended: fail, with an
   error that shows the escape hatch.*
6. **Remove the two existing annotation options?** external-dns is
   experimental, so its option can go in any release with an error naming
   the new setting. The VictoriaMetrics operator is stable, so its option
   can only go in 0.11. *Recommended: remove the external-dns one when it
   adopts the new setting, and remove the VictoriaMetrics one in 0.11.*
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
