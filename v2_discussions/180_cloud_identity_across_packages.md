# 180: Cloud identity when the ServiceAccount and the cloud provider live in separate packages

**Status:** Decided on 2026-11-24; implementation is pending.
**Related:** `177_workload_cloud_identity.md` (base workload cloud identity design), `kix/lib/vocab/cloud-identity.nix`, `kix/lib/architecture.md` (`deps` and `out` data flow)

## 1. The problem

`177_workload_cloud_identity.md` assumes one package owns the `ServiceAccount`
calling a cloud API and picks that cloud (as `external-dns` does with
`config.provider`). That breaks when two packages split those jobs:

| Software | Package that owns the `ServiceAccount` | Package that picks the cloud provider and credentials | Dependency direction |
|---|---|---|---|
| cert-manager | `cert-manager` builds `controllerServiceAccount` | `cluster-issuer` picks Route 53, Cloud DNS, or Azure DNS on each `ClusterIssuer` and holds any static credential `Secret` | Many `cluster-issuer` instances depend on one `cert-manager` instance |
| StackGres | `stackgres-cluster` configures the `SGCluster` from which the operator creates `<cluster>-patroni` | `stackgres-object-storage` configures the `SGObjectStorage` bucket, any static `Secret`, and the ambient-credential flag (`useIAMRole` or `fetchCredentialsFromMetadataService`) | Many `stackgres-cluster` instances can depend on one `stackgres-object-storage` instance |
| External Secrets | `external-secrets` builds the controller's `ServiceAccount` | The consumer package writes the `SecretStore`'s `provider` block | Each consumer package depends on `external-secrets` |

Without a shared rule, `cert-manager` puts the identity on the pod's instance
while StackGres puts it on shared storage and copies it to every cluster,
giving cluster authors two contradictory wiring models.

## 2. Four constraints that decide the design

1. **One identity per `ServiceAccount`, shared across many.** An annotation
   like `eks.amazonaws.com/role-arn` holds one role ARN, making cloud identity
   a `ServiceAccount` property even when several share a role.
2. **Trust policies bind per `(namespace, ServiceAccount)`.** Three clusters
   sharing one IAM role must list all three `ServiceAccount`s in its policy.
3. **Packages read `out` from dependencies and never see dependents.**
   `cert-manager` cannot inspect `cluster-issuer`; only the dependent sees both.
4. **Ambient credentials work without a `ServiceAccount` identity.** Pods fall
   back to the node's IAM role on self-managed clusters, so Kix cannot derive
   the ambient-credential flag from whether an identity is set.

## 3. Design rules

1. **Attach `deps.<name>` to the instance that owns the `ServiceAccount`,**
   once per `ServiceAccount` (built directly or created by an operator).
2. **Render the identity only there:** `credentials.bind` on a built
   `ServiceAccount`, or `kix.cloudIdentity.annotationsFor` for an operator's.
3. **Keep static `Secret`s and upstream's ambient-credential flags in the
   cloud-provider package,** which never accepts a cloud identity.
4. **Pass the cloud through `out` along the existing dependency** so the
   dependent package checks that both clouds match (two patterns in section 5).
5. **Reject mismatched clouds, and allow omitted identities** for node roles.

## 4. Changes to the Kix library

All helper changes are in `kix/lib/vocab/cloud-identity.nix`; plain `deps`
already reach `build` and `assertions`, and packages already read `out`.

```nix
# New. Read a dependency that takes a cloud identity or nothing.
kix.cloudIdentity.useIdentity {
  scope,
  dep,            # a cloud identity, or null
  secretGoesTo,   # where the Secret form is given, for the refusal's fix
  cloud,          # optional: the cloud, when a dependency's `out` gives it
                  # (null: that dependency reads a Secret). Leave it out
                  # when only dependents know the cloud.
}
# => { identity; cloud; bind; }     cloud: "aws" | "gcp" | "azure" | null

# New. Compare the cloud an object reaches with the pod's own credentials
# with the identity of `holder`, the dependency whose pods make the call.
kix.cloudIdentity.ambientProblem { cloud; holder; }
# => null, or { message; fix; } naming both instances and both clouds

# Changed. With `cloud = null`, the refusal of an identity adds
# `identityGoesTo` to its fix.
kix.cloudIdentity.use { scope; dep; cloud; identityGoesTo ? null; }

# Changed. `annotationsFor` takes `identity = null` and returns empty
# `serviceAccountAnnotations` and `podLabels`.
```

`useIdentity` rejects a `Secret` (naming `secretGoesTo`), validates the identity
alone when `cloud` is omitted, matches `use` on `"aws"`, `"gcp"`, or `"azure"`,
and rejects any identity when `cloud` is `null` (a `Secret`-backed dependency):
- **`out.identityCloud`** (on a `ServiceAccount` dependency like `cert-manager`)
  exposes `credentials.cloud` for `ambientProblem` (`null` when `null` or matching).
- **`out.ambientCloud`** (on a cloud-provider dependency like
  `stackgres-object-storage`) exposes `"aws"`, `"gcp"`, `"azure"`, or `null`
  (when reading a `Secret`), passed as `cloud` to `useIdentity`.

## 5. The two dependency patterns

### Pattern A: The cloud-provider package depends on the `ServiceAccount` package (`cert-manager`)

Today users attach annotations via `partsOverlays` without pod restarts on role
changes. With `useIdentity` and `ambientProblem`:

```nix
# on the cert-manager instance
deps.controllerIdentity = kix.cloudIdentity.aws {
  roleArn = "arn:aws:iam::111122223333:role/cert-manager";
};
# on the cluster-issuer instance. No key fields: cert-manager's own form
# for the pod's credentials.
config.spec.acme.solvers = [ { dns01.route53.region = "eu-west-1"; } ];
```

In the two packages:

```nix
# cert-manager: owns the ServiceAccount, cannot know the cloud
credentials = kix.cloudIdentity.useIdentity {
  inherit scope;
  dep = controllerIdentity;
  secretGoesTo = "`deps.issuerCredentials` of a cluster-issuer instance";
};
controllerServiceAccount =
  { apiVersion = "v1"; kind = "ServiceAccount"; inherit name labels; }
  |> credentials.bind |> scope.mkResource;
root.out.identityCloud = credentials.cloud;

# cluster-issuer: knows the cloud, checks each solver that sets no key
kix.cloudIdentity.ambientProblem { cloud = "aws"; holder = certManager; }
```

For a second AWS IAM role, an issuer sets the Route 53 solver's `role` field,
assumed from the controller's identity.

### Pattern B: The `ServiceAccount` package depends on the cloud-provider package (StackGres)

Today users set the ambient flag and `ServiceAccount` annotation via `extraSpec`
on two instances while `stackgres-object-storage` requires a `Secret` and writes
`secretKeySelectors`. With `out.ambientCloud` and `useIdentity`:

```nix
# on the stackgres-object-storage instance: StackGres's own switch, and
# no `storageCredentials`
config.extraSpec.s3.awsCredentials.useIAMRole = true;
# on each stackgres-cluster instance
deps.backupIdentity = kix.cloudIdentity.aws {
  roleArn = "arn:aws:iam::111122223333:role/orders-backup";
};
```

In the two packages:

```nix
# stackgres-object-storage: reads the switch from the spec it builds
root.out.ambientCloud = "aws";   # "gcp" for gcs, null when it reads a Secret

# stackgres-cluster: owns the ServiceAccount, reads the cloud from `out`
credentials = kix.cloudIdentity.useIdentity {
  inherit scope;
  dep = backupIdentity;
  cloud = sgObjectStorage.out.ambientCloud;
  secretGoesTo = "`deps.storageCredentials` of the stackgres-object-storage instance";
};
rendered = kix.cloudIdentity.annotationsFor {
  inherit scope;
  identity = credentials.identity;
  provider = cloudIdentity;        # the instance that holds the role
};
# spec.metadata.annotations.serviceAccount = rendered.serviceAccountAnnotations
```

Enabling `useIAMRole` or `fetchCredentialsFromMetadataService` omits
`secretKeySelectors`. Evaluation fails if an instance sets both the flag and
`deps.storageCredentials`, sets neither, or enables ambient credentials on
`s3Compatible` or `azureBlob` (unsupported in StackGres).

## 6. How the design handles edge cases

| Concern | Behavior |
|---|---|
| Multiple `ServiceAccount`s | Cluster authors write one identity dependency per `ServiceAccount`. Instances that share a role can share a `let` binding, and each declaration matches one `(namespace, ServiceAccount)` subject in the cloud trust policy. |
| Node credentials (no `ServiceAccount` identity) | Builds succeed. For `cert-manager`, the DNS-01 solver omits static key fields and `out.identityCloud` is `null`. For StackGres, `stackgres-object-storage` enables the ambient-credential flag and `stackgres-cluster` leaves `deps.backupIdentity` unset. |
| Pod restart on identity change | Automatic for `cert-manager`, because `cert-manager` both binds `controllerServiceAccount` and builds `controllerDeployment` (stamping `checksum/cloud-identity`). Kix adds no restart annotation to the pods of any `ServiceAccount` that an operator creates (such as StackGres database pods), because Kix does not build those pod templates. |
| Cluster has no cloud identity provider | Caught by `scope.mkResource` or `annotationsFor`. Because both run inside the instance where the cluster author wrote the identity, the error names that exact instance. |
| Missing credentials (`[K1798]` in `external-dns`) | Where ambient credentials use an explicit boolean field (`stackgres-object-storage`), the package rejects instances that set neither a `Secret` nor an enabled flag. `cert-manager` ACME solvers have no separate boolean field: omitting the static key fields tells `cert-manager` to use ambient credentials. |
| Static `Secret` fallback | Handled only by the package that selects the cloud provider (`cluster-issuer` or `stackgres-object-storage`). Passing a cloud identity there fails evaluation, and `identityGoesTo` points the fix to the instance that owns the `ServiceAccount`. |
| Unused cloud identity | Rejected for `stackgres-cluster` when `sgObjectStorage.out.ambientCloud` is `null` (meaning backups read a static `Secret` or are unset). Allowed on `cert-manager`, because another `cluster-issuer` may use it. |
| Kix DSL principles | Adds no custom instance attribute or invented Kubernetes manifest field: the ambient-credential flag is upstream's native spec field, the cloud identity is a `deps` value as in doc 177, and cloud metadata flows through `out`. Each decision has a single owner: the `ServiceAccount` instance owns the identity, the storage or issuer instance owns the cloud provider and static `Secret`, and the dependent package checks that they match. |

## 7. `external-secrets`

Kix has no store package; consumers call `externalSecrets.out.mkSecretStore`.

**A store with no `auth` block uses the controller's `ServiceAccount` (Pattern
A).** Unmerged pull request #340 passes `deps.controllerCredentials` and
`cloud = dep.cloud or null` to `kix.cloudIdentity.use`, reading a field packages
are not meant to read and turning off the cloud check. `useIdentity` with no
`cloud` is the named form (`secretGoesTo` replaces the `Secret` refusal), and
`mkSecretStore` calls `ambientProblem` for `aws`, `gcpsm`, and `azurekv`
providers with no `auth` block to reject cloud mismatches.

**A store naming its own `ServiceAccount` (`auth.jwt.serviceAccountRef`,
`auth.workloadIdentity.serviceAccountRef`, or Azure Key Vault
`serviceAccountRef`) is outside this rule and `kix.cloudIdentity`.** No pod runs
as that `ServiceAccount`. The External Secrets controller requests its token and
reads fixed annotation keys such as `eks.amazonaws.com/role-arn`. EKS Pod
Identity writes no annotation, an IRSA webhook with another prefix writes a key
the controller does not read, and Kix would refuse a cluster with no mechanism
though the controller needs none. The annotation is configuration that one
client reads, like the Vault role that doc 177 leaves out, so it belongs to the
package that runs the client:
- The consumer package writes plain annotations on the `ServiceAccount` it
  builds, using the keys External Secrets documents.
- `external-secrets` lists `eks.amazonaws.com`, `iam.gke.io`, and
  `azure.workload.identity` in `meta.annotationDomains` so the scorecard accepts
  them on any cluster.
- The Kix library gets no second render path (`bind` and `annotationsFor` stay
  tied to the cluster's mechanism).

## 8. Alternatives considered and the strongest objection

- **Always put the identity with the cloud provider.** Fails for `cert-manager`:
  two `cluster-issuer` instances could set conflicting roles on
  `controllerServiceAccount`, and `cert-manager` cannot read its dependents.
- **Two-case rule** (identity on `cert-manager`, StackGres identity in
  `deps.storageCredentials` on `stackgres-object-storage`). Configures all
  clusters in one line like `external-dns`, yet loses on four points: (1) two
  placement rules to learn; (2) clusters on one `SGObjectStorage` share one role
  and can read or delete each other's backups; (3) missing-provider or
  wrong-cloud errors fire on `stackgres-cluster` while the bad value sits on
  `stackgres-object-storage`; and (4) `stackgres-object-storage` still needs its
  ambient flag for node credentials (constraint 4).
- **Strongest objection.** StackGres needs the ambient flag on
  `stackgres-object-storage` plus `deps.backupIdentity` per `stackgres-cluster`;
  omitting `deps.backupIdentity` on a new cluster still builds and fails in the
  cloud or uses a broader node role, whereas `stackgres-object-storage` would
  annotate new clusters automatically.
- **Why the single rule wins.** Annotating from `stackgres-object-storage` still
  fails in the cloud until the IAM trust policy lists the new `<cluster>-patroni`
  `ServiceAccount`, and neither rule can forbid an ambient flag without an
  identity because node credentials use that setup. One rule stays consistent
  across packages, defaults to one role per cluster, and records every
  `ServiceAccount` subject the trust policy must name.

## 9. Build plan

1. **The Kix library.** Implement section 4 and test `useIdentity` (`null`,
   valid, `Secret`, malformed, and `cloud` matching, mismatched, omitted, or
   `null`), `ambientProblem` (none, matching, mismatched), `use`
   (`identityGoesTo`), and `annotationsFor` (`identity = null`) in
   `kix/lib/tests/units/cloud-identity.nix`. Update `kix/lib/architecture.md`,
   `docs/src/content/docs/reference/composition-helpers.mdx`, and the
   `package-authoring` and `package-review` skills. Change record: `added`.
2. **`cert-manager` and `cluster-issuer`.** Add `deps.controllerIdentity` and
   `out.identityCloud` to `cert-manager`; have `cluster-issuer` check keyless
   `route53`, `cloudDNS`, and `azureDNS` solvers and reject identities on
   `deps.issuerCredentials` (naming `deps.controllerIdentity`). Test each cloud,
   `Secret` beside a bound controller, mismatches, node credentials, and a
   cluster checking the `ServiceAccount` annotation, Azure pod label, and
   `checksum/cloud-identity`. Change records: `added` (neither took an identity).
3. **`stackgres-object-storage` and `stackgres-cluster`.** Verify in pinned
   StackGres CRDs (stopping if false) that `secretKeySelectors` is optional with
   ambient flags and `SGCluster`'s `spec.metadata.annotations.serviceAccount`
   reaches `<cluster>-patroni`. Update `stackgres-object-storage` (read ambient
   flags, omit `secretKeySelectors`, make `deps.storageCredentials` optional,
   and publish `out.ambientCloud`) and `stackgres-cluster` (`deps.backupIdentity`
   and `cloudIdentity`). Run step 2's tests plus two clusters with separate roles
   on one `stackgres-object-storage`. Change records: `added` for both, plus
   `error` for combining an ambient flag with `deps.storageCredentials`.
4. **`external-secrets`.** Update unmerged pull request #340 in place after step
   1: replace `use` (`cloud = dep.cloud or null`) with `useIdentity`, publish
   `out.identityCloud`, call `ambientProblem` in `mkSecretStore`, and list the
   three domains in `meta.annotationDomains`. Test stores with no `auth` block
   (bound and mismatched clouds), a `Secret` in `deps.controllerCredentials`,
   and a store naming an annotated `ServiceAccount` on a cluster with no
   mechanism. Point its two housekeeping entries at this doc or delete them.
   Change record: `added`.

All five packages are experimental, so each step can ship in any release.

**Live cloud verification checklist:**
- **`cert-manager` on EKS, GKE, and AKS:** controller pod gets `AWS_ROLE_ARN`
  and `AZURE_CLIENT_ID`, keyless DNS-01 `Certificate` reaches `Ready`, identity
  changes restart the pod, solver `role` assumption works, and omitting the
  identity issues certificates via node DNS permissions.
- **StackGres on EKS and GKE:** `<cluster>-patroni` gets the annotation on new
  and running clusters (record whether running pods need an `SGDbOps` restart),
  `SGBackup`, WAL archiving, and restore work, and two clusters with separate
  roles on one `SGObjectStorage` cannot read each other's backup paths.
