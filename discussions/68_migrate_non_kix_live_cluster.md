# 68: Migrating a Non-kix Live Cluster

**Status:** Draft
**Related:** `29_compiler-design.md`, `67_stateful_migration_orchestration.md`

---

## 1. Problem

When you adopt kix on a cluster that already runs workloads (deployed via Helm, plain manifests, Ansible, or anything else), a vanilla `kix deploy` will produce resources that *work* but don't *match* what's running. The consequences range from annoying to fatal:

| What changes | Severity | Why it hurts |
|---|---|---|
| Resource **name** | **Fatal** | K8s treats it as a new resource. Old one orphaned. StatefulSets lose their PVCs. |
| **Selector** labels | **Fatal** | Immutable on Deployments/StatefulSets after creation. Must delete & recreate. |
| **Metadata** labels | Medium | Monitoring queries, dashboards, alerting rules all break. Prometheus `{app="foo"}` stops matching. |
| **Annotations** | Low–Medium | Some annotations drive controller behavior (cert-manager, ingress, external-dns). Others are cosmetic. |
| **Namespace** | **Fatal** | Different namespace = different resource entirely. |

The goal is: kix should be able to produce output that is **adoption-safe** — the generated YAML matches the live cluster closely enough that applying it is a no-op (or a controlled, small diff).

---

## 2. What "Compatibility" Actually Means

This isn't just a Helm problem. Any existing cluster state has conventions that kix needs to match. The dimensions are:

### 2.1 Resource Names

Helm's default: `{{ .Release.Name }}-{{ .Chart.Name }}` or `{{ include "fullname" . }}`. Example: a Helm release named `my-immich` with chart `immich` produces resources named `my-immich-immich` or just `my-immich`.

kix's default: `scope.instanceName` — the instance key from the cluster definition. If you declare `instances.media.immich`, the name is `immich`.

**Mismatch is fatal.** If the live Deployment is named `my-immich` and kix produces `immich`, K8s sees a new Deployment. The old one stays, now unmanaged. PVCs bound to the old StatefulSet are orphaned.

**What's needed:** Per-instance name override, or a naming convention that can reproduce Helm's `fullname` template.

### 2.2 Selector Labels

Helm charts typically use:
```yaml
selector:
  matchLabels:
    app.kubernetes.io/name: immich
    app.kubernetes.io/instance: my-immich
```

Or the older convention:
```yaml
selector:
  matchLabels:
    app: immich
    release: my-immich
```

kix currently has two modes in `scope.nix`:
- `labelStyle = "kix"`: `{ "app.kubernetes.io/name" = instanceName; "app.kubernetes.io/instance" = instanceName; }` — note both keys get the same value
- `labelStyle = "helm"`: `{ app = instanceName; release = instanceName; }` — same, both get instanceName

**The problem:** Helm charts often have `name ≠ instance`. The chart name (`immich`) goes into `app.kubernetes.io/name`, the release name (`my-immich`) goes into `app.kubernetes.io/instance`. kix puts `instanceName` in both.

Selectors are **immutable** on Deployments and StatefulSets. If the live selector is `{ app.kubernetes.io/name: immich, app.kubernetes.io/instance: my-immich }` and kix produces `{ app.kubernetes.io/name: immich, app.kubernetes.io/instance: immich }`, you cannot update in-place. You must delete and recreate — which means downtime.

**What's already there:** `selectorLabelsOverride` on the instance module — you can set arbitrary selector labels. This solves it per-instance but requires the user to manually look up every running selector.

### 2.3 Metadata Labels

Beyond selectors, Helm charts stamp every resource with:
```yaml
labels:
  app.kubernetes.io/name: immich
  app.kubernetes.io/instance: my-immich
  app.kubernetes.io/version: "1.99.0"
  app.kubernetes.io/managed-by: Helm
  helm.sh/chart: immich-0.1.0
```

kix strips `helm.sh/chart` and replaces `managed-by` with `kix`. The other labels come from the scope.

**Impact:** Monitoring/alerting. If Prometheus scrapes with `{app_kubernetes_io_managed_by="Helm"}` or Grafana dashboards filter on `helm_sh_chart`, those break on adoption. This is a "medium" problem — it's fixable in monitoring config, but it's work.

### 2.4 Annotations

Some annotations are behavioral:
- `cert-manager.io/cluster-issuer` — drives certificate issuance
- `kubernetes.io/ingress.class` — routes to the right ingress controller
- `external-dns.alpha.kubernetes.io/hostname` — creates DNS records

These are set by packages, not by the framework, so they're already under user control. No framework-level compatibility issue.

Helm lifecycle annotations (`meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`) are stripped by `helm.nix` and must be stripped for adoption too — their presence tells Helm "I own this resource."

### 2.5 Resource Structure

Some Helm charts produce resources with specific field patterns that kix packages might not reproduce:
- Different volume names (Helm: `data`, kix: `storage`)
- Different container names (Helm: `server`, kix: `main`)
- Different port names (Helm: `metrics`, kix: `http`)

These aren't framework problems — they're per-package decisions. But they matter for adoption because existing PodMonitors, NetworkPolicies, etc. may reference specific port or container names.

---

## 3. What kix Already Has

| Mechanism | Where | What it does |
|---|---|---|
| `labelStyle = "helm"` | `modules.nix`, `scope.nix` | Switches selector/instance labels to `app`/`release` keys |
| `selectorLabelsOverride` | `modules.nix`, `scope.nix` | Arbitrary selector labels per instance |
| `clusterLabels` | `modules.nix`, `scope.nix` | Extra labels on every resource |
| Package-level `labels` | `scope.mkResource` | Packages can add arbitrary labels (highest priority) |
| Instance `name` = explicit | packages use `scope.instanceName` | You control the name by choosing the instance key |
| `partsOverlays` | `modules.nix` | Can patch any resource attribute post-build |

**What's missing:**

1. **No `name` override distinct from `instanceName`.** The instance key in the cluster definition *is* the name. If the Helm release was `my-immich-server`, your instance key must be `my-immich-server` — which is ugly and leaks deployment history into the logical model.
2. **No `app.kubernetes.io/name ≠ app.kubernetes.io/instance` split.** Both always get `instanceName`. Common Helm pattern is name=chartName, instance=releaseName.
3. **No way to say "keep `managed-by: Helm`" during transition.** Might be needed if you're doing a gradual migration where Helm and kix coexist.
4. **No adoption workflow.** There's no `kix adopt` that reads live state and generates the overrides you need.

---

## 4. Design: Instance-Level Overrides

Keep it minimal. Add the missing knobs without introducing a "compatibility mode" abstraction.

### 4.1 `resourceName` Override

```nix
# modules.nix — new option on instance submodule
resourceName = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  default = null;  # falls back to instance key
  description = ''
    Override the resource name passed to packages via scope.instanceName.
    Use when adopting resources whose names don't match the logical instance key.
    Example: instance key is "immich", but Helm named everything "my-immich-server".
  '';
};
```

When set, `scope.instanceName` returns `resourceName` instead of the instance key. The instance key remains the DI identity — resolution, deps, `kix list` all use the key. Only the generated YAML uses the override.

This is the single most important addition. It decouples **logical identity** (what kix calls the instance) from **K8s identity** (what the resources are named).

### 4.2 `appName` for Label Split

```nix
appName = lib.mkOption {
  type = lib.types.nullOr lib.types.str;
  default = null;
  description = ''
    Value for app.kubernetes.io/name (or "app" in helm labelStyle).
    Defaults to instanceName. Set when adopting Helm releases where
    chart name ≠ release name.
  '';
};
```

Then in `scope.nix`:

```nix
selectorLabels =
  if selectorLabelsOverride != null then selectorLabelsOverride
  else if labelStyle == "helm" then {
    app = appName or instanceName;
    release = instanceName;
  }
  else {
    "app.kubernetes.io/name" = appName or instanceName;
    "app.kubernetes.io/instance" = instanceName;
  };
```

This covers the common Helm case without needing the full `selectorLabelsOverride` escape hatch.

### 4.3 `extraLabels` / `extraAnnotations` on Instance

Already achievable via `partsOverlays` or package-level `labels`, but a direct instance-level option is cleaner for adoption:

```nix
extraLabels = lib.mkOption {
  type = lib.types.attrsOf lib.types.str;
  default = { };
  description = "Additional labels merged into every resource for this instance.";
};
```

These merge between `instanceLabels` and package `labels` in `scopeMkResource`.

### 4.4 `managedBy` Override

```nix
managedBy = lib.mkOption {
  type = lib.types.str;
  default = "kix";
  description = ''
    Value for app.kubernetes.io/managed-by. Set to "Helm" during
    gradual migration, then switch to "kix" when Helm is fully removed.
  '';
};
```

---

## 5. Adoption Workflow (Future)

The overrides above are the mechanism. The workflow is: how does the user *discover* what overrides they need?

### 5.1 Manual: `kix diff` Against Live

Already works today via `kix-dump.py` + `kix-diff.py`. The diff shows exactly what would change. The user reads the diff and adds overrides.

This is fine for a handful of services. It doesn't scale to 50+ Helm releases.

### 5.2 Assisted: `kix adopt` (Future CLI Command)

```
kix adopt --namespace media --release immich
```

Reads the live resources for a Helm release (via `helm get manifest` or label selector), compares against the kix-generated output, and emits a Nix snippet with the necessary overrides:

```nix
instances.media.immich = {
  package = packages.immich;
  resourceName = "my-immich-server";
  appName = "immich";
  selectorLabels = {
    "app.kubernetes.io/name" = "server";
    "app.kubernetes.io/instance" = "immich";
  };
};
```

This is a convenience tool, not a requirement. The overrides are the primitive; the tool generates them.

---

## 6. What This Doesn't Cover

- **Per-resource name overrides.** A Helm chart might name the Deployment `immich-server` and the Service `immich`. This design overrides the *instance* name, not individual resource names. Per-resource overrides are a `partsOverlays` concern — they're already possible, just verbose.
- **Helm secret ownership.** Helm tracks releases via Secrets (`sh.helm/release.v1`). Adopting a resource away from Helm requires either `helm uninstall --keep-history` or manually removing the Helm ownership annotations/labels. This is a Helm procedure, not a kix feature.
- **CRD adoption.** CRDs often have conversion webhooks, version storage, etc. that are tightly coupled to the operator that installed them. Adopting CRDs is an operator-migration problem, not a naming problem.
- **Stateful migration.** Covered by doc 67. This doc is about *identity* compatibility (names/labels), not *data* compatibility (PVC migration).

---

## 7. Open Questions

1. **Should `resourceName` affect all resources or just the "primary" ones?** A package might have a ConfigMap named `${name}-config` and a Service named `${name}`. If the Helm chart named them `my-immich-config` and `my-immich`, a single `resourceName` override doesn't help. Do we need per-part name overrides in the module system, or is `partsOverlays` sufficient?

2. **How far do we go with `managedBy`?** During transition, should kix be able to produce resources that Helm still considers "owned"? That means keeping `meta.helm.sh/release-name` annotations. This feels like it crosses from "compatibility" into "coexistence" — a different problem.

3. **Is `labelStyle` the right abstraction?** Currently it's an enum (`kix` | `helm`). Could become more values as we encounter other conventions (Kustomize, Argo, plain manifests). Alternatively, keep the enum small and push unusual cases to `selectorLabelsOverride`.
