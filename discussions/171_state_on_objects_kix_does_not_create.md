# 171: Declaring state on objects Kix does not create

**Status:** Draft (RFC)
**Related:** `125_backup_abstraction_levels_and_state_contract.md`, `123_compiled_delegation.md`, `108_backup_capability_contract.md`, `55_shared_resource_ownership.md`, GitHub issue 97

## 1. The need

Kix declares the objects it creates. Some objects in a cluster are created by
something else: a StatefulSet controller, an operator, or the Kubernetes
distribution. Sometimes a cluster needs one of those objects to carry a label
or an annotation, and needs it to stay there.

Issue 97 is the case that raised this. A cluster backup should take one copy
of a replicated database, skip caches, and skip volumes whose data is already
backed up elsewhere. Velero can skip a volume whose claim carries a given
label. The claims are made by a StatefulSet controller or an operator, so Kix
has no way to put the label on them. A label added with `kubectl` disappears
when the claim is recreated, and nothing reports that it has gone.

The same need already appears elsewhere in this repository:

| Case | How it is handled today |
|---|---|
| Backup labels on claims (issue 97) | Not handled |
| The Velero label on a VolumeSnapshotClass that the distribution ships | Not handled |
| Reflector annotations on a Secret that another program creates | A Job that runs `kubectl annotate` |
| Node labels that a storage engine needs | `kubectl label node`, run by a person |
| The default-class annotation on a StorageClass that the distribution ships | Kix refuses a second default class |
| Pod Security labels on `kube-system` | Kix applies the whole Namespace object |
| Labels on pods and Services that an operator creates | The operator's own setting, where it has one |

Cases we expect later include the reclaim policy of provisioned volumes,
backup hooks on pods an operator creates, and cost labels.

These cases differ in three ways, and the differences decide what can serve
them:

- **Is the name known at build time?** A distribution's StorageClass has a
  fixed name. A claim made by an operator may not.
- **Is the object created once, or again and again?** A node is registered
  once. A claim is recreated when a replica is rebuilt, when a volume is
  restored, and when a set scales down and up.
- **Does the decision depend on other objects?** "Skip this cache" depends on
  nothing else. "Keep exactly one of these three" depends on the other two.

## 2. What we tested

All tests ran on 2026-11-13 on a single-node kind cluster with Kubernetes 1.37.

**A label-only apply to an existing object works.** We applied a manifest that
held only a claim's name and one label, with Server-Side Apply and field
manager `kix`, to a claim that a StatefulSet controller had created. The API
server accepted it, and Kix's field manager entry held that one label and
nothing else. The same apply to a claim that did not exist failed with a
validation error and created nothing.

**CloudNativePG publishes what a backup needs.** With CloudNativePG 1.30.1,
the version Kix packages:

- Every claim carries `cnpg.io/instanceRole`, set to `primary` or `replica`.
  After we destroyed the primary and its claims, the labels showed the new
  primary within 15 seconds. After a planned switchover they changed within
  10 seconds.
- A label set in `spec.inheritedMetadata` reached every claim, including the
  claim of the rebuilt instance.
- The rebuilt instance took the same name as the one it replaced. Releases up
  to 1.29 gave a rebuilt instance a new number. Release 1.30.0 reuses the
  lowest free number, so claim names stay within `<cluster>-1` to
  `<cluster>-<instances>`.

The operator's source says the role labels are not updated while a failover
is in progress, and that claims are updated one at a time. A backup taken in
that window can see no primary, or two.

**An admission policy keeps a label on claims it has never seen.** Section 4
describes this feature and the test.

## 3. Proposal

A package or a cluster declares that objects matching a description carry a
label or an annotation. Kix chooses how to make that true. There are four
ways, and Kix uses the first one that fits.

**1. The creator writes it.** Most operators can pass labels through to the
objects they create, and a StatefulSet copies labels from its claim template.
Packages already use these settings. This serves any label that every member
of a set should carry: "skip, this is a cache" or "skip, this database backs
itself up".

**2. Select on what the creator already publishes.** Nothing is written. The
package publishes a selector for the objects in question, as operator packages
already do with `out.operandSelectors` for network policy. CloudNativePG's
role label is the example: a Velero policy that skips claims labelled
`cnpg.io/instanceRole: replica` takes one copy of each cluster.

**3. An admission policy.** Kix renders a rule that the API server applies
whenever a matching object is created or updated. The rule is an ordinary Kix
object. It covers objects whose names are chosen at run time, and it holds
between deploys. Section 4 gives the detail.

**4. A label-only apply at deploy.** For a single object with a fixed name,
such as a distribution's StorageClass or a node, Kix waits for the object to
exist and then applies only the labels or annotations it declares. The other
fields stay with whoever owns them.

The declaration covers labels and annotations only. Other fields of an object
belong to the controller that reconciles it, and a second writer would be
overwritten or would cause a conflict on every reconcile.

A sketch of the declaration, to show its shape. The names are placeholders.

```nix
(kix.annotateExisting {
  kind = "PersistentVolumeClaim";
  selector = { "app.kubernetes.io/instance" = scope.name; };
  exceptMember = 0;
  labels = { "backup.kix.run/skip" = "true"; };
})
```

Kix compiles this to way 3. A declaration that names one object compiles to
way 4. A package that can use way 1 or way 2 does not need the declaration at
all.

We found no case that needs a controller running in the cluster. Section 7
says when one would be needed.

## 4. Admission policies

### What the feature is

Every create or update of an object passes through the API server before it
is stored. This includes requests from controllers and operators. A
`MutatingAdmissionPolicy` is a rule that the API server runs at that point,
and the rule can change the object before it is stored.

The older way to do this is a mutating webhook, which is a service that
someone has to run and keep available. A policy is an object in the cluster,
and the API server evaluates it without calling anything.

The feature is stable and on by default from Kubernetes 1.36
(`admissionregistration.k8s.io/v1`). In 1.34 and 1.35 it is beta and off by
default.

### The two objects

A policy says what to match and what to change. A binding says where the
policy applies. This pair labels every claim of one StatefulSet except the
claim of member 0:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicy
metadata: {name: backup-one-copy-db}
spec:
  failurePolicy: Ignore
  reinvocationPolicy: IfNeeded
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["persistentvolumeclaims"]
  matchConditions:
    - name: member-of-set
      expression: "has(object.metadata.labels) && object.metadata.labels.exists(k, k == 'set') && object.metadata.labels['set'] == 'db'"
    - name: not-the-kept-member
      expression: "!object.metadata.name.endsWith('-0')"
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >
          Object{metadata: Object.metadata{labels: {"backup.kix.run/skip": "true"}}}
---
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingAdmissionPolicyBinding
metadata: {name: backup-one-copy-db}
spec:
  policyName: backup-one-copy-db
  matchResources:
    namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: default}
```

- `matchConstraints` filters by kind and operation.
- `matchConditions` filters further with CEL expressions over the incoming
  object. All of them must be true.
- `mutations` gives the change. `ApplyConfiguration` is a partial object that
  the API server merges in. `JSONPatch` is the other form.
- `failurePolicy` says what happens when the rule itself fails. `Ignore` lets
  the object through unchanged. `Fail` rejects the request.
- A binding can name a parameter object, such as a ConfigMap, which the
  policy reads as `params`. One policy can then serve many bindings.

### What the test showed

With that pair applied to a three-member StatefulSet:

- We deleted member 2's claim and pod. The new claim carried the label.
- We scaled the set to five. Claims 3 and 4 carried the label, and claim 0
  did not.
- We removed the label from claim 3 with `kubectl`. The request succeeded and
  the label was still there, because the rule also runs on updates.

The test used `failurePolicy: Fail`. The example above shows `Ignore`, which
we recommend and have not yet tested.

### Limits

- **A rule sees one object.** It reads the object in the request, its
  namespace, and the parameter object. It cannot read other claims, so it
  cannot count members or tell which member is the primary. "Exactly one of
  N" is possible only as a rule on the name, such as "every member except
  member 0".
- **A rule runs only when a request arrives.** A claim that exists before the
  policy does is unchanged until something updates it.
- **A rule cannot create or delete objects.**
- **The cluster must run Kubernetes 1.36 or later.** That release dates from
  April 2026, and many production clusters run older versions. Until a
  cluster upgrades, ways 1, 2, and 4 are what it has.

### Why this fits Kix

The policy and its binding are resources that Kix builds, like any other. The
plan shows them, the drift check covers them, and removing the declaration
removes them. Kix does not write to the claim, so there is no shared
ownership of the claim to reason about. The declaration stays a statement
about the cluster, and the API server keeps it true.

## 5. The backup choice, worked through

Doc 125 proposes that a package declares facts about its volumes and the
cluster declares the policy. Issue 97 needs two facts that doc 125 lacks:
"these volumes are copies of one another" and "this data is spread across
these volumes". With those, each kind of volume has a route:

| What the package declares | What the backup should do | How |
|---|---|---|
| Cache or scratch space | Skip every volume | Way 1 |
| The database backs itself up, and the cluster relies on that | Skip every volume | Way 1 |
| Data spread across members | Take every volume, or none | Way 1, or no label |
| Copies of one another, and the operator labels roles (CloudNativePG) | Take one | Way 2 |
| Copies of one another, in a StatefulSet | Take one | Way 3, keeping member 0 |

Three rules apply to all of them.

**A claim with no label is backed up.** Every route marks the volumes to
skip. A label that goes missing then costs storage and loses no data. With
way 2 on CloudNativePG, the policy should skip `replica` for the same reason:
a moment with two primaries gives two copies. A moment with no primary gives
none, and section 8 lists that as open.

**The package says which member to keep.** Any member is good enough when the
backup is taken. At restore time the kept member matters: if the other
members come back empty and one of them starts first, some databases will
treat the empty one as the primary. A StatefulSet starts member 0 first, so
member 0 is the default.

**The cluster decides the policy.** "Rely on the database's own backups" and
"skip this volume" are choices for the cluster definition. The package only
says what is true of its volumes.

Velero's rules shape the lowering. A `pvcLabels` condition matches when the
claim carries every listed label, there is no way to match the absence of a
label, and the first matching policy wins. A `skip` action applies to CSI
snapshots, snapshot data movement, and file-system backup alike.

A rule that warns about a volume with no backup decision can reuse the walk
over claims and claim templates in `kix/lib/eval/validate.nix`, which the
quota check already uses. It sees only what is visible at build time, so an
operator package has to declare the claims its operator will make.

## 6. What Kix needs

- **A way to ask whether the cluster serves an API.** Way 3 needs Kubernetes
  1.36. Today a package can read `clusterConfig.k8sVersion`, which is often
  unset, and there is no capability for a served API. When the cluster cannot
  serve the policy, the build should say so and name the ways that remain.
- **One touch of existing objects at deploy.** A new policy does not change
  claims that already exist. After the policy is applied, the deploy lists
  the matching objects and sends each one an update that changes nothing, so
  that the API server runs the rule.
- **Pruning that withdraws fields.** This is for way 4. Today an object that
  Kix has a field manager entry on, and that carries Kix's identity label, is
  pruned by deleting it. An object Kix only annotates must be recorded as
  such, and pruning must remove Kix's labels and leave the object.
- **Waiting for the object.** Way 4 applies only to an object that exists.
  `kix.untrackedRef` already makes a deploy wait for an object that another
  resource creates, and way 4 can build on it.
- **The plan and the drift check.** For ways 3 and 4 the plan should show
  what Kix will add and to which objects. For way 4 the drift check can
  compare the labels Kix applied, as it does for any field Kix owns.

## 7. Alternatives considered

**Kix creates the claims before the StatefulSet does.** A StatefulSet uses a
claim that already exists under the expected name, so Kix could render the
claims with the labels it wants. Rejected: Kix would have to produce exactly
the claim that the StatefulSet controller or the operator would have made,
and would take that job away from the component that expects to do it. Any
difference between the two would surface as a storage fault.

**A Job that runs `kubectl label`.** The reflector package does this today.
It runs once per deploy, so a recreated object stays unlabelled until the
next deploy, and the plan cannot show what the Job will do. Ways 3 and 4
replace it.

**A mutating webhook.** It can do what an admission policy does and can also
read other objects. It is a service that must be running for objects to be
created at all, and its logic is code that the plan cannot show.

**A controller that reconciles continuously.** A controller can watch every
claim and keep exactly one of a set marked, whatever the names. It is needed
only when all of these hold: the names are chosen at run time, the decision
depends on other objects, and the creator publishes nothing to select on. No
case we found meets all three. If one appears, the declaration in section 3
stays the same and the controller becomes a fifth way to carry it out.

## 8. Open questions

1. **The failover window on CloudNativePG.** Skipping `replica` gives no copy
   if a backup starts while no claim is labelled `primary`. How long is that
   window in practice, and should the Velero package retry or alert when a
   set yields no volume?
2. **Which member to keep, per package.** Member 0 suits a StatefulSet that
   starts in order. Each database package needs to confirm that a restore
   with only that member's data comes back correctly.
3. **`failurePolicy`.** `Ignore` fits backup labels because a missing label
   is safe. Is there a case where a missing label is unsafe and `Fail` is
   right, and should the declaration expose the choice?
4. **Clusters below Kubernetes 1.36.** Should "take one copy" on a
   StatefulSet be refused there, or fall back to taking every copy with a
   warning?
5. **Fields other than labels and annotations.** The reclaim policy of a
   provisioned volume is a `spec` field. Is that a separate feature, or a
   later extension of this one?
6. **Nodes.** A node is registered once and its name is known to the cluster
   definition, so way 4 fits. Should node labels and taints go through this
   declaration or through the flavour that provisions the node?
7. **The name of the declaration,** and whether packages call it directly or
   only through higher-level facts such as the volume facts of doc 125.
