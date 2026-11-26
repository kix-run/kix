# RFC: Deriving RBAC Rules and Webhooks from CRD Definitions

## Working Document — March 2026

**Status:** Proposal
**Related:** `29_compiler-design.md` (compiler passes, RBAC DSL), `lib/rbac.nix` (existing RBAC DSL), `lib/crd.nix` (CRD transforms), `lib/eval/scope.nix` (mkCRD)

---

## 1. The Problem

Operator packages maintain three parallel lists that must stay in sync: CRD definitions, webhook configurations, and RBAC rules. When a CRD is added or renamed, all three lists need updating. When they drift, the failure mode is a runtime error — a webhook that doesn't fire, a permission denied from the API server, or a CRD the operator can't reconcile.

### 1.1 stackgres-operator: Three Lists, One Truth

The stackgres-operator package demonstrates the problem clearly:

**List 1 — CRDs** (lines 787-855): 10 CRDs defined via `scope.mkCRD`:
```
sgCluster, sgInstanceProfile, sgPostgresConfig, sgPoolingConfig,
sgBackupConfig, sgObjectStorage, sgDistributedLogs, sgShardedCluster,
sgScript, sgDbOps
```

**List 2 — Webhook resources** (lines 40-93): 13 entries in `webhookResources`, each with `singular` and `plural` fields. This list does NOT match the CRD list — it includes `sgbackup`, `sgshardedbackup`, `sgshardeddbops`, `sgstream` which are not in the CRD list, and excludes `sgbackupconfig`. The singular/plural names must exactly match the CRD's `spec.names` or the webhook won't intercept the right resources.

**List 3 — RBAC rules** (lines 251-550): The ClusterRole has a `sgCrdNames` list (15 entries — a third enumeration of resource types), plus separate rules blocks for `stackgres.io` resources, status subresources, and finalizers. Each of these re-enumerates the CRD plurals.

In total, stackgres-operator lists its CRD resource names **five separate times** across these three concerns. Adding a new CRD type requires touching all five locations.

### 1.2 cert-manager: Same Pattern, More Components

cert-manager has 6 CRDs split across two API groups (`cert-manager.io` and `acme.cert-manager.io`). The same resource names appear in:

1. **CRD definitions** (lines 518-701) — `scope.mkCRD` calls
2. **RBAC ref groups** (lines 162-172) — `cm = group "cert-manager.io" [...]` and `acme = group "acme.cert-manager.io" [...]`
3. **Webhook configurations** (lines 1062-1141) — hardcoded `apiGroups` and `resources` in webhook rules
4. **RBAC intents** (lines 220-338) — `cm.certificates |> reconcile`, `acme.orders |> own`, etc., each referencing CRD resource names

The RBAC ref groups (item 2) are defined by hand-typing the plural resource names. These must match the CRD's `spec.names.plural`. If cert-manager renames a CRD plural, the `group` call won't break — it'll just generate RBAC rules for a resource that doesn't exist.

### 1.3 Why This Matters

These aren't hypothetical risks. The concrete failure modes:

- **Webhook miss**: Add a CRD but forget to add it to the webhook list. The operator starts without admission control on that resource type. Invalid CRs get created, the operator crashes trying to reconcile them.
- **RBAC gap**: Add a CRD but forget to add it to the ClusterRole. The operator gets `403 Forbidden` when trying to reconcile that resource. Appears as intermittent failures because the operator retries.
- **Name mismatch**: CRD uses plural `sgpgconfigs` but webhook rule says `sgpostgresconfigs`. Webhook never fires for that resource. Silent failure.
- **Status/finalizer omission**: Add a CRD to the main RBAC list but forget to add the `/status` and `/finalizers` subresource rules. Operator can read/write the CR but can't update status or set finalizers.

All of these are **structurally preventable**. The CRD definition already contains the group, plural name, and scope. That's enough to derive webhook rules and RBAC rules.

---

## 2. CRD as Source of Truth

A CRD definition — specifically `scope.mkCRD` output — contains:

| Field | Location in CRD spec | Used by |
|---|---|---|
| API group | `spec.group` | Webhook rules, RBAC apiGroups |
| Plural name | `spec.names.plural` | Webhook rules, RBAC resources |
| Singular name | `spec.names.singular` | Webhook path construction |
| Kind | `spec.names.kind` | Webhook name field |
| Scope | `spec.scope` | Whether RBAC is cluster-scoped or namespaced |
| Versions | `spec.versions[*].name` | Webhook apiVersions |

From this, we can derive:

### 2.1 Operator RBAC — "I reconcile my own CRDs"

Every operator needs full access to its own CRDs. Given a list of CRDs, derive:

```
# For each CRD:
- apiGroups: [group], resources: [plural], verbs: [get, list, watch, create, update, patch, delete]
- apiGroups: [group], resources: [plural/status], verbs: [patch, update]
- apiGroups: [group], resources: [plural/finalizers], verbs: [update]
```

This is the `stackgres.io` block at lines 487-540 of stackgres-operator — three rule blocks that are 100% derivable from the CRD list.

### 2.2 CRD Management RBAC — "I manage my own CRD definitions"

Operators that self-manage CRDs need:

```
- apiGroups: [apiextensions.k8s.io], resources: [customresourcedefinitions],
  resourceNames: [plural.group for each CRD], verbs: [get, patch, update]
- apiGroups: [apiextensions.k8s.io], resources: [customresourcedefinitions],
  verbs: [list, create]
```

This is the `sgCrdNames` block at lines 251-379 of stackgres-operator.

### 2.3 Validating Webhooks

For each CRD, a validating webhook entry:

```
name: "<singular>.validating-webhook.<group>"
rules: [{ apiGroups: [group], apiVersions: [versions], resources: [plural], operations: [CREATE, UPDATE, DELETE] }]
clientConfig.service: { name: <webhook-service>, namespace: <ns>, path: "/validation/<singular>" }
```

This is exactly what `mkValidatingWebhook` does in stackgres-operator (lines 95-120), but taking the resource info from a separate list instead of from the CRD.

### 2.4 Mutating Webhooks

Same pattern with different operations and path prefix.

### 2.5 Consumer RBAC — "I need to create CRs of this type"

When a package depends on another package's CRDs (e.g., an app creating `Certificate` CRs from cert-manager), the consumer needs RBAC rules for those CRDs. The RBAC ref (`group "cert-manager.io" ["certificates" ...]`) is derivable from the CRD definition.

---

## 3. Proposed API

### 3.1 CRD Set Declaration

A new `mkCRDSet` on scope that takes a list of CRDs and produces derived resources:

```nix
# In stackgres-operator/default.nix:

crds = scope.mkCRDSet {
  group = "stackgres.io";
  definitions = {
    sgCluster = scope.crd.fromKind "SGCluster" {}
      |> scope.crd.withShortNames [ "sgclu" ];

    sgPostgresConfig = scope.crd.fromKind "SGPostgresConfig" {
      spec.names = { singular = "sgpgconfig"; plural = "sgpgconfigs"; };
    } |> scope.crd.withShortNames [ "sgpgc" ];

    # ... rest of CRDs
  };
};
```

The `crds` output is an attrset with:

```nix
crds.sgCluster          # CRD resource (same as scope.mkCRD output)
crds.sgPostgresConfig   # CRD resource
crds.rbacRef            # rbac group ref for all CRDs in this set
crds.rbacRef.sgclusters # individual ref (usable with |> reconcile, etc.)
```

### 3.2 Operator RBAC Derivation

A new RBAC intent, `operatorFor`, that derives the full operator permission set from a CRD set:

```nix
# Replaces the 60-line stackgres.io RBAC block:
operatorRbac = grant [
  (crds.rbacRef |> rbac.operatorFor)    # full CRUD + status + finalizers for all CRDs
  (crds |> rbac.manageCRDs)             # apiextensions.k8s.io permissions for CRD lifecycle
  # ... non-CRD rules remain manual:
  (core.pods |> full)
  (core.secrets |> full)
];
```

`rbac.operatorFor` expands to, for each CRD in the set:
- `full` on the resource
- `allow ["patch" "update"]` on `resource/status`
- `allow ["update"]` on `resource/finalizers`

`rbac.manageCRDs` expands to:
- `get`, `patch`, `update` on `customresourcedefinitions` scoped to `resourceNames`
- `list`, `create` on `customresourcedefinitions` (unscoped, required for discovery)

### 3.3 Webhook Derivation

A webhook builder that takes a CRD set and a service reference:

```nix
# Replaces the webhookResources list + mkValidatingWebhook + mkMutatingWebhook:

validatingWebhook = scope.mkClusterResource {
  apiVersion = "admissionregistration.k8s.io/v1";
  kind = "ValidatingWebhookConfiguration";
  name = name;
  extra.webhooks = crds |> webhook.validating {
    service = self.operatorService;
    pathPrefix = "/stackgres/validation";
    failurePolicy = "Fail";
    timeoutSeconds = 10;
    sideEffects = "None";
    # Optional: override per-CRD settings
    overrides.sgCluster.operations = [ "CREATE" "UPDATE" ];  # no DELETE
  };
};

mutatingWebhook = scope.mkClusterResource {
  apiVersion = "admissionregistration.k8s.io/v1";
  kind = "MutatingWebhookConfiguration";
  name = name;
  extra.webhooks = crds |> webhook.mutating {
    service = self.operatorService;
    pathPrefix = "/stackgres/mutation";
    failurePolicy = "Fail";
    timeoutSeconds = 10;
    sideEffects = "None";
    operations = [ "CREATE" "UPDATE" ];  # default for all CRDs in this set
  };
};
```

The webhook builder reads `spec.names.singular`, `spec.names.plural`, `spec.group`, and `spec.versions[*].name` from each CRD in the set to produce webhook entries. The service name and namespace come from the service resource's `.out`.

### 3.4 Consumer RBAC Refs

When a package depends on cert-manager and needs to create `Certificate` CRs:

```nix
# Current (manual — must know the plural name and API group):
cm = group "cert-manager.io" [ "certificates" "issuers" ];

# Proposed (derived from the CRD):
certManager.crds.certificates |> rbac.fromCRD |> allow [ "create" "get" "list" "watch" ]
# or use the set-level ref:
certManager.crds.rbacRef.certificates |> allow [ "create" "get" "list" "watch" ]
```

The CRD resource already knows its group and plural. `rbac.fromCRD` extracts those into an RBAC ref.

### 3.5 Full Example — stackgres-operator Rewritten

```nix
let
  crds = scope.mkCRDSet {
    group = "stackgres.io";
    definitions = {
      sgCluster = scope.crd.fromKind "SGCluster" {}
        |> scope.crd.withShortNames [ "sgclu" ];
      sgInstanceProfile = scope.crd.fromKind "SGInstanceProfile" {}
        |> scope.crd.withShortNames [ "sginp" ];
      sgPostgresConfig = scope.crd.fromKind "SGPostgresConfig" {
        spec.names = { singular = "sgpgconfig"; plural = "sgpgconfigs"; };
      } |> scope.crd.withShortNames [ "sgpgc" ];
      # ... etc
    };
  };
in
{
  inherit crds;

  clusterRole = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = name;
    extra.rules = grant [
      (crds.rbacRef |> rbac.operatorFor)
      (crds |> rbac.manageCRDs)
      # Non-CRD rules remain manual — these are operator-specific:
      (core.pods |> full)
      (core.secrets |> full)
      # ... etc
    ];
  };

  validatingWebhook = scope.mkClusterResource {
    apiVersion = "admissionregistration.k8s.io/v1";
    kind = "ValidatingWebhookConfiguration";
    name = name;
    extra.webhooks = crds |> webhook.validating {
      service = self.operatorService;
      pathPrefix = "/stackgres/validation";
      failurePolicy = "Fail";
      timeoutSeconds = 10;
      sideEffects = "None";
    };
  };

  # ... rest of package
}
```

---

## 4. What's Derived vs. What's Manual

### Fully Derivable (should never be hand-written)

| Concern | Derived from |
|---|---|
| RBAC: operator CRUD on its CRDs | CRD group + plural |
| RBAC: operator status/finalizer subresources | CRD group + plural |
| RBAC: CRD definition management (apiextensions.k8s.io) | CRD group + plural (for resourceNames scoping) |
| Webhook: apiGroups, apiVersions, resources in rules | CRD group, versions, plural |
| Webhook: name field (`<singular>.<type>-webhook.<group>`) | CRD singular, group |
| Consumer RBAC: ref construction (group + plural) | CRD group + plural |

### Partially Derivable (sensible defaults, override when needed)

| Concern | Default | Override example |
|---|---|---|
| Webhook operations | Validating: CREATE, UPDATE, DELETE. Mutating: CREATE, UPDATE | Some CRDs only need CREATE validation |
| Webhook path | `/<prefix>/<singular>` | Operator uses a non-standard path scheme |
| Webhook scope | `"*"` (all namespaces) | Restrict to specific namespaces |

### Always Manual (cannot be derived from CRD definition)

| Concern | Why |
|---|---|
| Webhook `failurePolicy` | Business decision: Fail vs Ignore |
| Webhook `sideEffects` | Depends on webhook implementation |
| Webhook `timeoutSeconds` | Performance tuning |
| Webhook `clientConfig.caBundle` / CA injection | Depends on cert management strategy |
| Webhook `namespaceSelector` / `objectSelector` | Policy decision |
| Non-CRD RBAC (pods, secrets, events, etc.) | Operator-specific, depends on what the operator manages beyond its CRDs |
| RBAC for third-party CRDs (VPA, Prometheus, KEDA) | These are external dependencies, not owned CRDs |
| `reinvocationPolicy` for mutating webhooks | Depends on mutation behavior |

### The 80/20 Line

In stackgres-operator, roughly 150 lines of the 550-line ClusterRole rules block are derivable from CRDs. The remaining 400 lines cover non-CRD resources (pods, secrets, statefulsets, etc.) and third-party API access. The derivation eliminates the most error-prone part — the part that must stay in sync with CRD definitions — while leaving the genuinely operator-specific RBAC as explicit declarations.

For webhooks, the entire `webhookResources` list (50 lines) plus `mkValidatingWebhook` and `mkMutatingWebhook` helpers (50 lines) collapse into two `webhook.validating`/`webhook.mutating` calls.

---

## 5. Interaction with Existing RBAC DSL

### 5.1 `rbac.operatorFor` as a New Intent

`operatorFor` joins the existing intent family (`watch`, `reconcile`, `own`, `full`, `readWrite`, `finalize`, `emit`, `allow`). It operates on a CRD set ref rather than a single ref, but produces standard `[Rule]` output that flows through `grant` unchanged:

```nix
# These compose naturally:
grant [
  (crds.rbacRef |> rbac.operatorFor)     # derived CRD rules
  (core.pods |> full)                     # manual non-CRD rules
  (core.events |> emit)                   # manual non-CRD rules
]
```

`grant` already handles merging and deduplication. No changes to `grant` are needed.

### 5.2 `rbac.fromCRD` as a Ref Constructor

`rbac.fromCRD` is analogous to `rbac.group` — it constructs a ref. The difference is that `group` takes strings, while `fromCRD` takes a CRD resource and extracts the strings from it:

```nix
# Equivalent:
cm = rbac.group "cert-manager.io" [ "certificates" ];
cm = rbac.fromCRD certManager.crds.certificates;

# Both produce refs usable with existing intents:
cm.certificates |> watch
cm.certificates |> reconcile
```

### 5.3 `mkClusterRoleSet` / `mkRoleSet` Unchanged

The derived rules are just `[Rule]` values. They slot into `mkClusterRoleSet` and `mkRoleSet` the same way hand-written rules do:

```nix
controllerClusterRoles = mkClusterRoleSet scope {
  subjects = mkControllerSubject self.controllerServiceAccount;
  roles = {
    "${name}-controller-crds" = grant [
      (crds.rbacRef |> rbac.operatorFor)
      (crds |> rbac.manageCRDs)
    ];
    "${name}-controller-core" = grant [
      (core.pods |> full)
      (core.secrets |> full)
    ];
  };
};
```

### 5.4 CRD Set Ref and Existing Intents

The `crds.rbacRef` behaves like a `group` — it's an attrset of refs. Individual CRDs within the set are accessible as attrs and work with all existing intents:

```nix
# Use existing intents on individual CRDs from the set:
crds.rbacRef.sgclusters |> watch         # just watch, not full operator access
crds.rbacRef.sgclusters |> reconcile     # reconcile pattern
crds.rbacRef |> rbac.operatorFor         # full operator pattern for entire set
```

This means you can mix derived and manual intents freely — `operatorFor` for the bulk, then override specific CRDs:

```nix
grant [
  (crds.rbacRef |> rbac.operatorFor)
  # But for sgconfigs, we also need deletecollection:
  (crds.rbacRef.sgconfigs |> allow [ "deletecollection" ])
]
```

---

## 6. Migration Path

### Phase 1: Add `rbac.fromCRD` and `rbac.operatorFor`

Add new functions to `lib/rbac.nix`. No changes to existing packages. New packages can opt in.

**Concrete steps:**
- Add `fromCRD` to `rbac.nix` — extracts group/plural from a CRD resource's spec
- Add `operatorFor` intent — expands to full + status + finalizers for a ref or list of refs
- Add `manageCRDs` — expands to apiextensions.k8s.io rules scoped to CRD names

### Phase 2: Add `scope.mkCRDSet`

Wrap multiple `mkCRD` calls into a set that exposes `.rbacRef`:

**Concrete steps:**
- Add `mkCRDSet` to scope — takes `{ group, definitions }`, returns attrset of CRD resources + `.rbacRef`
- Ensure individual CRD resources retain their current API (`.out.mkCR`, etc.)

### Phase 3: Add `webhook.validating` / `webhook.mutating`

Webhook derivation as a new `lib/webhook.nix`:

**Concrete steps:**
- New library that takes a CRD set + config, returns webhook entry list
- Expose via `scope.webhook`

### Phase 4: Migrate stackgres-operator

Replace the three manual lists with the derived versions. This is a good first migration because:
- All CRDs share one API group (`stackgres.io`)
- Webhook patterns are uniform (same failurePolicy, sideEffects, timeout for all)
- The RBAC rules are clearly structured into CRD-derived vs. non-CRD sections

**Verification:** `nix build` the package, diff the output YAML against the current output. The resources should be identical (or intentionally improved — e.g., fixing the webhook/CRD list mismatch).

### Phase 5: Migrate cert-manager

More complex because:
- Two API groups (`cert-manager.io` and `acme.cert-manager.io`) — needs two CRD sets or a multi-group set
- Webhook is a separate component (not the controller) — service reference differs
- RBAC is split across three components (controller, webhook, cainjector) with different permission levels

This migration validates the API works for multi-component operators.

---

## 7. Open Questions

1. **Single-group vs. multi-group CRD sets.** stackgres-operator has one group. cert-manager has two. Should `mkCRDSet` take a single `group` (requiring two sets for cert-manager) or support mixed groups (with `group` on each definition)? The single-group version is simpler and covers the common case. Two sets for cert-manager is not onerous.

2. **Where does `webhook` live?** As a new `lib/webhook.nix` (parallel to `lib/rbac.nix`)? Or as methods on the CRD set object? The former is more consistent with the existing architecture. The latter is more discoverable.

3. **Webhook resources beyond CRDs.** stackgres-operator's webhook list includes resources (`sgbackup`, `sgstream`) that are NOT in the CRD list defined in the package. These are CRDs the operator manages at runtime, not at deploy time. Should `mkCRDSet` support "webhook-only" entries — resources that get webhook rules but not CRD resources? Or should those be separate manual webhook entries?

4. **Consumer RBAC ergonomics.** When package A depends on cert-manager and needs to create Certificates, is `certManager.crds.rbacRef.certificates |> allow [...]` significantly better than `cm.certificates |> allow [...]` where `cm = group "cert-manager.io" ["certificates"]`? The derived version prevents typos in the group/plural, but it requires the dependency to expose its CRD set. Today, packages can construct RBAC refs for any API group without a dependency — is that a feature or a bug?

5. **CRD set vs. flat CRD attrset.** The current `crds = { sgCluster = scope.mkCRD ...; ... }` is a plain attrset. `mkCRDSet` would return a richer object. Should the CRD resources still be accessible as `crds.sgCluster` (the set IS the attrset with extra attrs), or should they be nested as `crds.definitions.sgCluster`? The former is more ergonomic but risks name collisions with `rbacRef` and other derived attrs.

6. **`operatorFor` granularity.** The proposed `operatorFor` gives full CRUD + status + finalizers. Some operators only need read access to certain CRDs they don't own. Should `operatorFor` be the only derived intent, or should there be `controllerFor` (read + update + status), `watcherFor` (read-only), etc.? Alternatively, `operatorFor` covers the common case and you use `crds.rbacRef.someCrd |> watch` for the exceptions.

7. **Webhook extra entries.** stackgres-operator has a separate `sgconfig` webhook that follows a different pattern (different path, different operations). Should the CRD set webhook builder support per-CRD config overrides (proposed in 3.3), or should outliers be manual webhook entries appended to the derived list?

8. **Validation: CRD list vs. webhook list consistency.** Even with derivation, a package might have webhooks for CRDs it doesn't define (external CRDs, runtime-managed CRDs). Should the compiler warn when a webhook references a resource not in any CRD set? This is a whole-cluster check (the CRD might be defined in another package).
