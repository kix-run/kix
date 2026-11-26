# 88b: Flux vs kix — Technical Comparison and Migration

**Status:** Design Doc
**Related:** `88_kustomize_integration.md`, `28_gitops_deploy.md`, `87_helm_integration_v2.md`

---

## What Flux Is

Flux is a set of Kubernetes controllers that implement a pull-based GitOps
reconciliation loop. It watches sources (git repos, OCI artifacts, Helm repos)
and continuously reconciles their contents into the cluster.

Flux's controllers:

| Controller | CRD | What it does |
|---|---|---|
| source-controller | `GitRepository`, `OCIRepository`, `HelmRepository`, `Bucket` | Fetches artifacts from external sources on a poll interval. Produces a versioned tarball (`.tar.gz`) of the source content. |
| kustomize-controller | `Kustomization` | Runs `kustomize build` on a source path, then applies the output via server-side apply. Handles health checking, dependency ordering, pruning, variable substitution. |
| helm-controller | `HelmRelease` | Runs `helm install/upgrade` against the cluster. Manages release lifecycle, rollback on failure, value overrides, test hooks. |
| notification-controller | `Alert`, `Provider`, `Receiver` | Sends notifications on events (Slack, Teams, webhook). Receives webhooks to trigger reconciliation. |
| image-reflector + image-automation | `ImageRepository`, `ImagePolicy`, `ImageUpdateAutomation` | Scans container registries for new tags, updates git repo with new image refs. |

The key architectural decisions and why they exist:

### Why runtime reconciliation (not CI)

Flux chose runtime reconciliation for specific technical reasons:

**1. Pull model eliminates credential exposure.**
CI push requires cluster credentials in the CI environment. Every CI runner
becomes a lateral movement target. Flux inverts this: the cluster pulls from
git. The cluster has a git read token (low-privilege, revocable). The CI
system never touches the cluster API.

**2. Continuous drift correction without CI triggers.**
`kubectl edit`, `kubectl delete`, operator side-effects, admission webhook
mutations — all produce drift that CI can't see until the next push. Flux's
poll interval (default 10m) catches drift regardless of how it was introduced.
This is the main operational argument.

**3. Multi-cluster without CI fan-out.**
Each cluster runs its own Flux instance pulling from the same repo (different
paths). No CI matrix of `deploy-to-cluster-{1..N}` jobs. Adding a cluster =
bootstrap Flux on it, point at the repo. No CI pipeline changes.

**4. In-cluster secret handling.**
Flux's kustomize-controller integrates with SOPS and Mozilla SOPS directly.
Decryption happens inside the cluster. The encrypted secret file lives in git;
the cleartext never leaves the cluster boundary. CI-based approaches either
decrypt in CI (secrets in CI env) or need an in-cluster operator anyway
(sealed-secrets, external-secrets).

### Why `Kustomization` wraps `kustomize build`

Flux's `Kustomization` CRD is not just "run kustomize build." It adds:

**1. `dependsOn` — ordered deployment across kustomization boundaries.**
A Flux repo typically splits infra from apps. `dependsOn` ensures CRDs and
operators are healthy before CRs are applied. Kustomize (the tool) has no
concept of cross-directory ordering — it operates on a single directory.
Flux adds this at the controller level.

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
spec:
  dependsOn:
    - name: infrastructure  # wait for this to be healthy first
  path: ./apps/production
```

**2. `postBuild.substitute` — runtime variable injection.**
Kustomize (the tool) has no variable substitution. Flux adds `envsubst`-style
substitution after `kustomize build`, sourced from ConfigMaps/Secrets in the
cluster. This lets cluster-specific values (cloud provider, region, account
IDs) stay in-cluster rather than in git.

```yaml
spec:
  postBuild:
    substitute:
      CLUSTER_NAME: production-eu-west
    substituteFrom:
      - kind: ConfigMap
        name: cluster-info
```

**3. Health checking and gating.**
After apply, Flux waits for health (Deployment rollout, StatefulSet ready,
custom health checks via `status.conditions`). `dependsOn` consumers don't
proceed until the dependency's health checks pass. This is the runtime
equivalent of kix's wave engine — but Flux's ordering is manually declared
via `dependsOn`, not derived from a dependency graph.

**4. Pruning via label ownership.**
Flux labels every applied resource with
`kustomize.toolkit.fluxcd.io/name` and `/namespace`. Resources whose label
matches a `Kustomization` but are no longer in its output get pruned
(`prune: true`). This is Flux's garbage collection — cruder than kix's
content-addressed ownership (labels can collide, renaming a Kustomization
orphans everything) but operationally simple.

**5. Force apply and SSA field management.**
Flux uses server-side apply with a named field manager (`kustomize-controller`).
`force: true` resolves field ownership conflicts by taking ownership of all
conflicting fields. This matters when migrating resources from `kubectl` or
Helm to Flux — existing field managers block SSA without force.

### Why `HelmRelease` exists alongside `Kustomization`

Flux treats Helm as a first-class deployment mechanism, not just a rendering
step. `HelmRelease`:

- Runs `helm install/upgrade/rollback` against the cluster, maintaining Helm
  release state (Helm secrets in the cluster)
- Rolls back automatically on failed upgrade (`remediation.retries`)
- Supports `valuesFrom` (ConfigMap/Secret in cluster) for runtime value
  injection
- Supports `postRenderers` — kustomize patches applied after `helm template`
  but before apply (this is the Flux answer to "I need to patch a Helm chart
  without forking it")

kix's position: Helm rendering should happen at build time, not deploy time.
`importChart` (doc 87) runs `helm template` during Nix eval. The cluster
never runs `helm install`. There are no Helm release secrets, no Helm
rollback machinery, no runtime value injection. All of these are eliminated
by making rendering a compile step.

---

## Feature-by-Feature Mapping

| Flux feature | Why Flux has it | kix equivalent | Status |
|---|---|---|---|
| **GitRepository polling** | Pull model: cluster fetches source | Operator watches OCI artifact or git ref | Open (doc 62) |
| **Kustomization apply** | Runtime `kustomize build` + SSA | `importKustomization` at eval time + `kix deploy` SSA | `deploy` done, `importKustomization` doc 88 |
| **HelmRelease** | Runtime `helm upgrade` | `importChart` at eval time + `kix deploy` | `deploy` done, `importChart` doc 87 |
| **dependsOn** | Manual cross-kustomization ordering | DI graph → automatic DAG ordering | Done (wave engine) |
| **Health gating** | Wait for rollout before dependents | Per-wave health checks in deploy | Done |
| **Pruning** | Label-based ownership GC | Content-hash ownership via DAG | Done |
| **Drift detection** | Continuous reconcile loop | `kix health` (CLI) + operator (planned) | CLI done, operator open |
| **Self-healing** | Revert manual edits | Reconcile loop re-applies on hash mismatch | Open (M2) |
| **postBuild.substitute** | Runtime env injection | Nix eval (all values known at build time) | N/A — eliminated by design |
| **SOPS decryption** | In-cluster secret handling | Deploy-time SOPS hydration (doc 77b) | In progress |
| **Notifications** | Alert on deploy events | Planned (M4) | Open |
| **Image automation** | Auto-update image tags from registry | Planned (M4) | Open |
| **Multi-tenancy** | Service account per Kustomization | Scoped deploy permissions | Open |
| **Suspend/resume** | Pause reconciliation | Planned | Open |
| **postRenderers** | Kustomize patches on Helm output | `patchResources` in `importChart` | Done |
| **Force SSA** | Take field ownership on conflict | `kix deploy` uses SSA with `kix` field manager | Done |
| **Retry with backoff** | Transient API server errors | Planned (M2) | Open |

### What kix does that Flux doesn't

| Capability | Why Flux can't do this |
|---|---|
| **Compile-time validation** (selector matching, RBAC linking, orphan detection) | Flux renders at runtime — no static analysis pass |
| **Automatic dependency ordering** from DI graph | Flux requires manual `dependsOn` declarations |
| **Cross-package type checking** (CRD refs, capability contracts) | Flux applies YAML — no resource relationship model |
| **Content-addressed immutable deploys** | Flux overwrites in-place (mutable SSA) |
| **Unified diff against live cluster** with full context | Flux diffs per-Kustomization, no cross-Kustomization view |

### What Flux does that kix doesn't (yet)

| Capability | kix status | Priority |
|---|---|---|
| **Continuous in-cluster reconciliation** | Operator skeleton exists, not production-ready | High (M2) |
| **Image update automation** | Not started | Low — CI-triggered re-eval is fine for now |
| **Multi-tenant RBAC** (service account per source) | Not started | Medium |
| **Webhook receivers** (GitHub, GitLab push → reconcile) | Not started | Medium — `kix deploy` from CI covers this |
| **Bucket source** (S3/GCS/Minio) | Not planned | Low — OCI is the standard |

---

## Migrating from Flux

### Repo structure mapping

Typical Flux repo:
```
clusters/
  production/
    flux-system/          # Flux bootstrap (source-controller, etc.)
    infrastructure.yaml   # Kustomization CRD → ./infrastructure/production
    apps.yaml             # Kustomization CRD → ./apps/production, dependsOn: infrastructure
infrastructure/
  base/
    cert-manager/
      kustomization.yaml  # kustomize (the tool)
    ingress-nginx/
      kustomization.yaml
  production/
    kustomization.yaml    # overlay: references ../base/*, patches
apps/
  base/
    my-app/
      deployment.yaml
      service.yaml
      kustomization.yaml
  production/
    kustomization.yaml    # overlay: patches replica count, image tag
```

Equivalent kix structure:
```
kix/packages/
  cert-manager/default.nix    # importKustomization or importChart
  ingress-nginx/default.nix
  my-app/default.nix
clusters/
  production.nix               # instances, config overrides
```

### Migration steps

**Step 1: Identify what each Flux `Kustomization` CRD points at.**

Each `Kustomization` CRD resolves to a directory. That directory contains
either:
- Pure kustomize YAML → use `importKustomization`
- A Helm chart reference (via kustomize's `helmCharts` field) → use `importChart` directly
- Plain YAML files → use `mkImport` or hand-wire

```bash
# Extract the mapping from a Flux repo
grep -r "path:" clusters/production/*.yaml
# infrastructure: path: ./infrastructure/production
# apps:           path: ./apps/production
```

**Step 2: Convert each `Kustomization` to a kix package.**

Flux `Kustomization`:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cert-manager
  namespace: flux-system
spec:
  interval: 1h
  sourceRef:
    kind: GitRepository
    name: fleet-repo
  path: ./infrastructure/base/cert-manager
  prune: true
  wait: true
  dependsOn:
    - name: crds
  patches:
    - target:
        kind: Deployment
        name: cert-manager
      patch: |
        - op: replace
          path: /spec/replicas
          value: 3
  postBuild:
    substitute:
      CLUSTER_REGION: eu-west-1
```

kix package:
```nix
# kix/packages/cert-manager/default.nix
{ scope, lib }:
let
  # If upstream ships a kustomize base:
  src = scope.kustomize.fetchKustomization {
    url = "https://github.com/cert-manager/cert-manager";
    path = "deploy/manifests";
    ref = "v1.16.0";
    hash = "sha256-...";
  };
  # Or if migrating the local kustomize directory as-is:
  # src = ./manifests;  # copy the kustomize dir into the package
in
{
  meta = {
    version = "1.16.0";
    provides = [ "cert-manager" ];
  };

  options = {
    replicas = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    # postBuild.substitute vars become typed options
    clusterRegion = lib.mkOption {
      type = lib.types.str;
      default = "eu-west-1";
    };
  };

  build = { config, ... }:
    let
      resources = scope.kustomize.importKustomization {
        inherit src scope;
        patchResources = map (r:
          if r.kind == "Deployment" && r.metadata.name == "cert-manager"
          then lib.recursiveUpdate r {
            spec.replicas = config.replicas;
          }
          else r
        );
      };
    in
    resources.mkParts {
      root = resources.get "Deployment" "cert-manager";
    };
}
```

What happened to the Flux fields:

| Flux field | Where it went |
|---|---|
| `interval: 1h` | Eliminated — kix deploys on change, not on timer. Operator reconcile interval is cluster-level, not per-package. |
| `sourceRef` | `fetchKustomization { url, ref, hash }` — pinned, hashed, reproducible. |
| `path` | `fetchKustomization { path = "..." }` or local directory. |
| `prune: true` | Default in kix — content-addressed ownership means orphans are always detected. |
| `wait: true` | Default in kix — wave engine always waits for health between waves. |
| `dependsOn: [crds]` | Automatic. If cert-manager's CRDs are in a CRD provider package, the DI graph creates the ordering edge. No manual declaration. |
| `patches` | `patchResources` or kix options. Typed, validated at eval time. |
| `postBuild.substitute` | kix options. `${CLUSTER_REGION}` becomes `config.clusterRegion`. Type-checked, no envsubst fragility. |

**Step 3: Convert the `dependsOn` tree to kix DI.**

Flux's dependency tree is manually declared. In kix, most of it is automatic:

```
Flux:                               kix:
infrastructure ← apps              packages declare `provides`/`requires`
  └─ crds ← cert-manager             → DI resolves ordering automatically
  └─ ingress ← apps                  → no dependsOn needed
```

For cases where the DI graph doesn't capture an ordering need (rare — usually
means the dependency should be explicit in the package), use `requires` in
the parts tree.

**Step 4: Wire the cluster definition.**

```nix
# clusters/production.nix
{
  instances.cert-manager.cert-manager = {
    package = packages.cert-manager;
    config = {
      replicas = 3;
      clusterRegion = "eu-west-1";
    };
  };

  instances.default.my-app = {
    package = packages.my-app;
    # DI auto-resolves cert-manager dependency
  };
}
```

**Step 5: Remove Flux.**

Once all `Kustomization` CRDs are migrated to kix packages and `kix deploy`
handles reconciliation:

```bash
flux uninstall
```

The Flux controllers, CRDs, and flux-system namespace are removed. kix's
operator (or CLI-driven deploy) takes over reconciliation.

### What can't migrate cleanly

**`postBuild.substituteFrom` referencing in-cluster ConfigMaps/Secrets.**
Flux reads values from live cluster objects and injects them into rendered
YAML. kix doesn't do runtime value injection — all values must be known at
eval time. Migration path: move the values into the cluster definition
(Nix code) or into a secrets management system (SOPS, doc 76).

**`valuesFrom` in HelmRelease referencing in-cluster Secrets.**
Same issue — runtime value injection. For secrets specifically, kix's SOPS
hydration (doc 77b) handles this: the encrypted value is in git, decrypted
at deploy time inside the cluster.

**Image update automation.**
Flux watches container registries and auto-commits updated image tags to git.
kix doesn't have this. The migration path is CI-triggered: a registry webhook
triggers a CI job that updates the package's image tag in Nix code, commits,
and deploys. Functionally equivalent but push-based instead of pull-based.

**Flux's notification system.**
`Alert` and `Provider` CRDs for Slack/Teams/webhook notifications on deploy
events. kix doesn't have this yet (M4). During migration, use CI pipeline
notifications or a webhook from `kix deploy --on-complete`.

---

## Conceptual Differences

**Flux separates source, render, and apply into distinct controllers.**
Each concern is a CRD and controller: source-controller fetches,
kustomize-controller renders and applies. They communicate via status
conditions on CRDs. This is the Kubernetes-native way: small controllers
watching CRDs, reconciling toward desired state.

**kix collapses source+render into a single eval step.**
Nix eval fetches sources (via derivations), renders (via IFD), and produces
the complete desired state. There's no intermediate CRD. The eval output is
the contract between "what should exist" and "make it so." This is simpler
(one step, not three) but means eval must have access to all sources — no
lazy fetching of individual components.

**Flux's dependency model is flat and manual.**
`dependsOn` is a list of names. No transitivity (if A depends on B depends
on C, A must list both B and C... actually Flux does handle transitivity
through health gating, but the declarations are still manual). No
type-checking (a typo in `dependsOn` is a runtime error).

**kix's dependency model is a typed DAG.**
Dependencies are declared via DI (`provides`/capability resolution) or
explicit `requires`. The graph is computed at eval time, type-checked
(missing capability = eval error), and transitively closed. This is
the fundamental advantage: the dependency graph is a compile-time artifact,
not a runtime discovery.

---

## Open Questions

### 1. Incremental migration: Flux and kix coexisting

During migration, some resources are Flux-managed and some are kix-managed.
They must not conflict. The mechanism: distinct SSA field managers.
Flux uses `kustomize-controller`, kix uses `kix`. As long as they manage
disjoint resource sets, SSA prevents conflicts.

The risk is shared resources: a Namespace created by Flux that kix also
wants to manage. Solution: kix's `mkImport` can reference existing resources
without taking ownership, or the namespace package uses
`meta.lifecycle = "adopt"` to take over field management gracefully.

### 2. Flux's multi-tenancy model

Flux supports per-`Kustomization` service accounts. Each tenant's
Kustomization runs with a scoped RBAC identity, preventing cross-tenant
resource access. kix doesn't have per-package deploy identity yet. For
multi-tenant clusters migrating from Flux, this is a gap until kix's
scoped deploy permissions are implemented (M4).

### 3. Flux's garbage collection edge cases

Flux prunes by label matching — resources labeled with a Kustomization's
name/namespace that are no longer in its output get deleted. This has known
edge cases (renaming a Kustomization orphans everything, cross-Kustomization
resource sharing causes double-ownership). kix's content-hash ownership
avoids these issues but introduces its own: content-addressed naming means
"updating" a resource creates a new one and prunes the old. For stateful
resources, this needs the lifecycle annotations from doc 81.
