# 180: Cloud identity when the ServiceAccount and the cloud choice are in two packages

**Status:** Decided on 2026-11-24. Not built.
**Related:** `177_workload_cloud_identity.md` (the design this extends), `kix/lib/vocab/cloud-identity.nix`, `kix/lib/architecture.md` (how `deps` and `out` flow)

## 1. The problem

Doc 177 assumes one package knows both the ServiceAccount whose pods call
the cloud and which cloud the software calls. external-dns does. Two
adopters do not, and a third looked as if it might not.

| | Who has the ServiceAccount | Who has the cloud choice, the switch, and the Secret | Which depends on which |
|---|---|---|---|
| cert-manager | `cert-manager` builds the controller's ServiceAccount | Each ClusterIssuer in `cluster-issuer` picks Route 53, Cloud DNS, or Azure DNS, and holds any static key | Many issuers depend on one `cert-manager` |
| StackGres | The operator creates `<cluster>-patroni` from the SGCluster in `stackgres-cluster` | The SGObjectStorage in `stackgres-object-storage` holds the bucket, the Secret, and the switch (`useIAMRole`, `fetchCredentialsFromMetadataService`) | Many clusters depend on one storage |
| external-secrets | The controller's, or one that a SecretStore names | The SecretStore's `provider` block | The package that builds a store depends on `external-secrets` |

One adopter proposed the identity where the pod is (cert-manager). The
other proposed it where the cloud choice is, copied by every cluster
(StackGres). Building both gives Kix two patterns.

## 2. Four facts that decide it

1. **A ServiceAccount carries one identity, and one identity may sit on
   many ServiceAccounts.** The IRSA annotation holds one role. So the
   identity is a property of the ServiceAccount.
2. **The cloud names each ServiceAccount.** The subject is always the pair
   (namespace, ServiceAccount name). A role that three database clusters
   share still needs three subjects in its trust policy.
3. **A package reads the `out` of what it depends on, and nothing reads its
   dependents.** `cert-manager` cannot see the issuers built on it. Only
   the package that depends on the other holds both facts.
4. **The switch for "use the pod's own credentials" works with no identity
   at all.** The pod then gets the role of its node, which is a valid
   setup. So the switch cannot be derived from the identity.

## 3. The rule

1. **The cluster author writes the identity on the instance that owns the
   ServiceAccount**: the one whose package builds it, or whose custom
   resource makes an operator create it. Each ServiceAccount gets its own
   line, as a dependency of that instance.
2. **Only that package renders it.** It calls `credentials.bind` on a
   ServiceAccount it builds, or `kix.cloudIdentity.annotationsFor` for one
   an operator creates.
3. **The Secret and the switch stay in the package that makes the cloud
   choice.** The switch is the software's own field on the object that
   package builds. That package never takes an identity.
4. **The cloud travels through `out`, along the dependency that already
   exists.** The package that depends on the other compares the identity's
   cloud with the cloud choice.
5. **A mismatch is refused. A missing identity is allowed**: with the
   switch on and no identity, the pods use the node's role.

A package author asks one question: do my resources create the
ServiceAccount? Rule 4 has two code shapes, set by which way the dependency
runs (section 5).

## 4. The library change

All of it is in `kix/lib/vocab/cloud-identity.nix`. Dependency resolution
does not change: a plain value in `deps` already reaches `build` and
`assertions`, and a package already reads its dependency's `out`.

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

`useIdentity` refuses a Secret instance and names `secretGoesTo`. With
`cloud` given, it refuses another cloud as `use` does, and refuses any
identity when `cloud` is null. `ambientProblem` reads
`holder.out.identityCloud` and returns null when it is null or matches.

Two `out` fields carry the cloud. A package that owns the ServiceAccount
publishes `out.identityCloud` (`credentials.cloud`) for the packages that
choose the cloud. A package that chooses the cloud for another package's
pods publishes `out.ambientCloud`, null when its object reads a Secret.

## 5. The two shapes

### The package with the ServiceAccount is depended on (cert-manager)

Today the author adds the annotation with `partsOverlays`, and the pods do
not restart when the role changes. After:

```nix
# on the cert-manager instance
deps.controllerIdentity = kix.cloudIdentity.aws {
  roleArn = "arn:aws:iam::111122223333:role/cert-manager";
};
# on the cluster-issuer instance. No key fields: cert-manager's own form
# for the pod's credentials.
config.spec.acme.solvers = [ { dns01.route53.region = "eu-west-1"; } ];
```

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

An issuer that needs another AWS role sets the solver's `role` field, which
cert-manager assumes from the controller's identity.

### The package with the ServiceAccount depends on the other (StackGres)

Today the author sets the switch and the annotation in two `extraSpec`
options, and the storage still writes Secret selectors. After:

```nix
# on the stackgres-object-storage instance: StackGres's own switch, and
# no `storageCredentials`
config.extraSpec.s3.awsCredentials.useIAMRole = true;
# on each stackgres-cluster instance
deps.backupIdentity = kix.cloudIdentity.aws {
  roleArn = "arn:aws:iam::111122223333:role/orders-backup";
};
```

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

With the switch on, the storage writes no selectors. It refuses the switch
together with a Secret, an instance with neither, and the switch on
`s3Compatible` and `azureBlob`, which have none.

## 6. The rule against each concern

| Concern | Result |
|---|---|
| Several ServiceAccounts | One line per ServiceAccount. Clusters that share a role share a `let` binding. The lines match the subjects the trust policy must name. |
| No identity, node credentials | Builds. cert-manager: a solver with no key and `identityCloud` null. StackGres: the switch on and no `backupIdentity`. |
| Restart stamp | Automatic for cert-manager, because the package that binds also builds the Deployment. None for StackGres pods, as for every ServiceAccount an operator creates. |
| No mechanism on the cluster | Raised by `scope.mkResource` or `annotationsFor`. Both run in the instance where the author wrote the identity, so the error names that instance. |
| No credentials at all (`[K1798]` in external-dns) | The package with the Secret and the switch refuses "no Secret and switch off" where the switch is a field (`stackgres-object-storage`). A cert-manager solver has no such state: leaving the keys out is the switch. |
| Secret fallback | Only the package that makes the cloud choice sees it. An identity given there is refused, and the fix names the other instance (`identityGoesTo`). |
| An identity nobody uses | Refused for StackGres (`cloud` is null). Allowed for cert-manager, where another issuer may use it. |
| Kix's DSL principles | No instance key and no manifest field: the switch is upstream's field, and the identity is a `deps` value as in doc 177. The cloud is read from the dependency's `out`. Each decision has one owner: the role belongs to the instance with the ServiceAccount, the cloud and the switch to the instance with the bucket or the DNS zone, and the check to the one package that sees both. |

## 7. external-secrets

Kix has no package for a store. A package builds one with
`externalSecrets.out.mkSecretStore`, and the rule covers both forms.

- **A store with no auth block** uses the controller's ServiceAccount.
  `external-secrets` owns it and takes the identity with `useIdentity`. It
  also builds the store, inside `mkSecretStore`, and checks the cloud there.
- **A store that names a ServiceAccount** (`auth.jwt.serviceAccountRef`,
  `auth.workloadIdentity.serviceAccountRef`). The package that builds the
  store builds that ServiceAccount and writes the `provider` block, so it
  calls `use` and `bind` as external-dns does. The controller reads the
  role from the annotation, which EKS Pod Identity does not write.

## 8. The rule not chosen, and the strongest objection

**Identity always where the cloud choice is** fails for cert-manager: two
issuers could give one ServiceAccount two roles, and `cert-manager` cannot
read its dependents.

**A two-case rule** keeps this doc's answer for cert-manager and puts the
identity on the storage for StackGres, in `storageCredentials`. It is
close: it reads like external-dns, and one line covers every cluster. It
loses on four points. A cluster author gets two answers to "where do I
write the role". Every cluster on a storage shares one role, so each can
read and delete the others' backups. The errors for a missing mechanism or
a wrong cloud come from each cluster while the value sits on the storage.
The storage needs its switch without an identity anyway (fact 4).

**The strongest objection.** For StackGres the author now makes two
statements in two instances: the switch on the storage and the role on each
cluster. Add a cluster, forget the role, and the build passes. The backup
then fails in the cloud, or succeeds with the node's wider role. With the
identity on the storage, a new cluster cannot miss it.

**Answer.** A new cluster can still miss its role under that design, in
the cloud. It is a new subject that the trust policy must name, nothing in
the cluster file says so, and the backup fails in the same way. Kix cannot
refuse "switch on, no identity" under either rule, because that is how node
credentials are written. The chosen rule gives one answer for every
package, a role per cluster by default, and a line in the cluster file for
each subject the cloud must know.

## 9. Build plan

1. **Library.** Section 4. Unit tests in
   `kix/lib/tests/units/cloud-identity.nix`: `useIdentity` with null, an
   identity, a Secret, a malformed identity, and `cloud` matching,
   differing, and null; `ambientProblem` with no identity, a match, and a
   mismatch; `use` with `identityGoesTo`; `annotationsFor` with null.
   Docs: `reference/composition-helpers.mdx`, `kix/lib/architecture.md`,
   and the `package-authoring` and `package-review` skills. Record: `added`.
2. **cert-manager and cluster-issuer.** `deps.controllerIdentity`,
   `out.identityCloud`, and the check on each `route53`, `cloudDNS`, and
   `azureDNS` solver that sets no key field. `cluster-issuer` refuses an
   identity in `issuerCredentials` and names `controllerIdentity`. Tests:
   each cloud, a Secret solver beside a bound controller, the mismatch, and
   node credentials, plus a test cluster whose manifests show the
   annotation, the Azure pod label, and `checksum/cloud-identity`. Records:
   `added` for each package. No existing definition fails, because the
   refusal needs an identity that could not be given before.
3. **stackgres-object-storage and stackgres-cluster.** The storage reads
   its switch, drops the selectors, makes `storageCredentials` optional,
   and publishes `out.ambientCloud`. The cluster takes
   `deps.backupIdentity` and the `cloudIdentity` role provider. First
   confirm two facts in the CRDs of the pinned StackGres release, and stop
   if either is false: the selectors may be left out when the switch is on,
   and `spec.metadata.annotations.serviceAccount` reaches
   `<cluster>-patroni`. Tests as in step 2, plus two clusters with two
   roles on one storage. Records: `added` for each package, and one `error`
   for the storage, which now refuses the switch together with a Secret.

All four packages are experimental, so each step can ship in any release.

**A test on a real cloud must check:**

- **cert-manager, on EKS, GKE, and AKS.** The controller pod carries the
  injected variables (`AWS_ROLE_ARN`, `AZURE_CLIENT_ID`). A Certificate
  reaches Ready through a DNS-01 solver with no key. A changed role
  restarts the controller. An issuer with the solver's `role` field assumes
  that role. On nodes that hold the DNS permission, an instance with no
  identity still issues.
- **StackGres, on EKS and GKE.** The operator puts the annotation on
  `<cluster>-patroni`, for a new cluster and for one that already runs.
  Record whether running pods need an SGDbOps restart to pick the role up.
  An SGBackup completes, WAL archiving works, and a restore reads the
  backup. Of two clusters with two roles on one storage, neither can read
  the other's path.
