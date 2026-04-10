# 89: Eval Operator Mode — Nix Evaluation Inside the Cluster

**Status:** RFC
**Related:** `88b_flux_comparison_and_migration.md`, `43_activation_operator.md`, `62_operator_production_implementation_plan.md`, `36_rust_oracle_at_fixpoint.md`, `01_evaluateCluster_merging.md`, `28_gitops_deploy.md`

---

## Problem

The current operator model (doc 62) is push-based:

```
dev machine / CI:  nix eval → DAG → kix artifact push → OCI registry
cluster:           operator pulls OCI artifact → applies manifests
```

This requires a CI pipeline or manual push step between "code changed" and
"cluster converges." The cluster never sees Nix code — it only receives
pre-rendered manifests. This is the right default (simple operator, small
image, reproducible builds), but it has costs:

1. **Cluster credentials leak outward.** Either CI has a kubeconfig, or CI
   pushes to OCI and the operator pulls. The first is a security risk. The
   second is safe but requires OCI registry infrastructure.

2. **CI is a bottleneck.** Every change goes through the pipeline: push →
   CI triggers → nix eval → artifact push → operator pulls → deploy. For
   platform teams iterating on cluster config, this loop is slow.

3. **Multi-cluster requires CI fan-out.** Each cluster needs a CI job or
   a matrix entry. Adding a cluster means modifying CI config.

4. **Teams can't self-serve.** A team that wants to change their package
   config must go through the same CI pipeline as every other change. No
   per-team deploy autonomy.

Flux solves all four by running the render step (`kustomize build`) inside
the cluster. The cluster pulls source, renders, and applies — no CI in the
loop. Doc 88b maps the trade-offs in detail.

**The question:** what if the kix operator runs `nix eval` inside the cluster?

---

## Proposal

Add an **eval mode** to the kix operator. Instead of consuming pre-rendered
OCI artifacts, the operator clones a git repo, runs `nix eval`, and feeds
the resulting DAG into the existing apply engine.

```
Eval operator mode:
  cluster: operator watches git → pulls repo → nix eval → DAG → applies

Current mode (unchanged, remains the default):
  external: nix eval → DAG → OCI push
  cluster:  operator pulls OCI → applies
```

Both modes share the identical apply engine (wave ordering, health gating,
pruning, drift detection). The only difference is where the DAG comes from.

### Activation CR extension

Doc 43 already sketches this — the Activation CR's `spec.source` has a
`type: git` variant:

```yaml
apiVersion: kix.dev/v1alpha1
kind: Activation
metadata:
  name: production
spec:
  source:
    type: git
    repo: https://github.com/org/infra.git
    ref: main
    flakeAttr: cluster-production
    pollInterval: 5m
    # Optional: restrict eval to specific fragments (see §Team Fragments)
    fragments:
      - path: teams/backend/
        gitRef: teams/backend/main

  policy:
    driftRemediation: auto
    failureStrategy: halt
```

The operator flow becomes:

```
1. Poll git ref (or receive webhook)
2. Clone repo at ref (shallow clone, depth=1)
3. nix eval .#<flakeAttr> → activation store path
4. Load DAG from store path (same as storePath/OCI mode)
5. DIFF → PLAN → APPLY → PRUNE (existing engine, unchanged)
```

---

## What Eval-in-Cluster Enables

### 1. Pure pull model — no credentials leave the cluster

The cluster has a git read token (low-privilege, revocable, rotatable).
Nothing else. No kubeconfig in CI, no OCI push credentials in CI, no
registry infrastructure needed. This is Flux's core security model —
eval-in-cluster gives kix the same property.

For private registries (fetchHelmChart, container images), the operator
pod's service account gets image pull secrets. These already exist in most
clusters for workload images.

### 2. No CI pipeline for deploy

Push to git → operator polls → eval → deploy. The CI pipeline is
eliminated for the deploy path. CI still runs tests, linting, `kix diff`
in PRs — but the actual deploy is the cluster's job.

This cuts deploy latency from minutes (CI queue + build + push + poll) to
seconds (poll interval + eval + apply). For platform teams iterating on
cluster config, this is a significant improvement.

### 3. Multi-cluster without fan-out

Each cluster runs its own operator, pointing at the same repo with a
different `flakeAttr`:

```yaml
# cluster-eu-west
spec:
  source:
    repo: https://github.com/org/infra.git
    flakeAttr: cluster-eu-west

# cluster-us-east
spec:
  source:
    repo: https://github.com/org/infra.git
    flakeAttr: cluster-us-east
```

Adding a cluster = bootstrap the operator + create an Activation CR.
No CI changes. Each cluster evals independently, at its own pace, with
its own cache.

### 4. Team-scoped fragment editing — self-service deploy

This is where eval-in-cluster enables something Flux can't do well.

kix's cluster merging model (doc 01) already supports multiple independent
cluster definition fragments merged before the fixpoint. In eval mode,
each team can own a fragment:

```
infra-repo/
  flake.nix
  clusters/production.nix          # platform team — base cluster
  teams/
    backend/cluster-fragment.nix   # backend team — their instances
    data/cluster-fragment.nix      # data team — their instances
```

The `flake.nix` merges fragments:

```nix
cluster-production = evaluateCluster [
  ./clusters/production.nix       # platform team base
  ./teams/backend/cluster-fragment.nix
  ./teams/data/cluster-fragment.nix
];
```

With eval-in-cluster, a team pushes to their fragment → the operator
re-evals the full cluster (including all fragments) → deploys only what
changed. The team never touches CI. They don't need cluster credentials.
They push Nix code, the operator compiles and deploys it.

**What this looks like for a team:**

```nix
# teams/backend/cluster-fragment.nix
# Backend team owns this file. They can:
# - Add/remove instances in their namespace
# - Change config on their packages
# - Bump versions
# All changes get full compile-time validation (DI, selectors, RBAC)
{
  instances.backend.api = {
    package = packages.api;
    config = {
      replicas = 3;
      image = "api:v2.1.0";   # team bumps this themselves
    };
  };

  instances.backend.worker = {
    package = packages.worker;
    config.concurrency = 10;
  };
}
```

The platform team controls what packages are available, what namespaces
exist, what resource quotas apply. The backend team controls what runs
in their namespace within those constraints. The compile step enforces
all constraints — a team can't deploy to a namespace they don't own,
can't exceed resource quotas, can't reference packages they don't have
access to.

**Compared to Flux multi-tenancy:** Flux gives each team a `Kustomization`
CRD with a scoped service account. The team's RBAC limits what K8s API
calls they can make. But there's no compile-time validation — a team can
submit YAML that passes RBAC but is semantically wrong (broken selectors,
missing ConfigMaps, wrong port numbers). kix catches all of this at eval
time, before anything touches the cluster.

### 5. Job submission — compiled ad-hoc compute

This is a capability no existing tool offers.

A team writes a Nix expression for a Job, submits it (via git push or a
CRD), and the operator compiles it with full cluster context:

```nix
# teams/data/jobs/backfill-2026-04.nix
{ scope, lib }:
{
  meta.version = "1.0.0";

  build = { self, config, clusterConfig }:
    let
      # DI gives us the postgres instance — correct hostname, port,
      # credentials secret ref. No hardcoding.
      db = self.deps.postgres;

      job = scope.mkJob {
        name = "backfill-2026-04";
        containers.backfill = {
          image = "data-team/backfill:v3";
          env = {
            DATABASE_URL = db.out.connectionString;
            # mkSecretRef wires the right secret + key
            DATABASE_PASSWORD = db.out.passwordRef;
          };
          resources = {
            requests = { cpu = "2"; memory = "4Gi"; };
            limits = { cpu = "4"; memory = "8Gi"; };
          };
        };
      };
    in {
      root.resource = job;
    };
}
```

What the operator does with this:

1. **Compiles** the job with the cluster's DI context — `self.deps.postgres`
   resolves to the actual postgres instance, with its real hostname, port,
   secret references.
2. **Validates** at compile time — the postgres dependency exists, the
   secret ref is valid, resource requests are within the namespace quota,
   the container image exists in the allowed registry.
3. **Generates** the correct RBAC — if the job needs to read a secret,
   the ServiceAccount + RoleBinding are auto-generated.
4. **Generates** NetworkPolicies — the job needs to talk to postgres,
   so a CNP allowing that traffic is auto-created (doc 37).
5. **Applies** via the wave engine — ServiceAccount and RBAC first, then
   the Job itself, then the NetworkPolicy.

Compare this to `kubectl create job`: no DI, no RBAC generation, no
network policy, no compile-time validation, manual secret wiring,
manual service URL discovery.

Compare to Flux/Argo: they can apply a Job YAML, but can't compile it
with cluster context. The team hardcodes `postgres.data.svc.cluster.local`
and hopes the hostname is right.

**CronJobs work the same way.** A team defines a CronJob package, the
operator compiles it with DI context, and it runs on schedule with
correct wiring. Version bumps to the postgres package automatically
update the CronJob's environment variables — because the DI graph
propagates the change.

### 6. Branch preview environments

The operator can eval a branch and deploy it to an isolated namespace:

```yaml
apiVersion: kix.dev/v1alpha1
kind: Activation
metadata:
  name: preview-feature-xyz
spec:
  source:
    type: git
    repo: https://github.com/org/infra.git
    ref: feature/xyz
    flakeAttr: cluster-preview
  policy:
    ttl: 24h  # auto-cleanup after 24 hours
```

The preview cluster definition imports the same packages but scopes
everything to a preview namespace. The operator evals the branch, deploys,
and garbage-collects after TTL. No CI pipeline needed.

### 7. Live cluster-aware validation

When eval runs in-cluster, the Rust oracle (doc 36) could optionally
query cluster state for validation that requires runtime information:

- **CRD existence checking.** Does the CRD this CR targets actually exist
  on this cluster? Today this is a runtime error. With in-cluster eval,
  the oracle can check the API server's discovery endpoint.
- **Node capacity validation.** The cluster definition requests 3 replicas
  with 8Gi each. The oracle checks: does this cluster have enough
  allocatable memory? Warning if not.
- **Storage class validation.** A PVC requests `storageClassName: fast-ssd`.
  The oracle checks: does this storage class exist?

**Important constraint:** these must be **read-only validation queries**,
not value injection. The eval output must still be deterministic from the
git input alone. The oracle adds warnings/errors, not values. If you remove
the oracle queries, the same YAML comes out — you just lose the warnings.

This preserves functional purity: the eval result depends only on git
content. The oracle provides advisory diagnostics, not semantic input.

---

## Operator Architecture for Eval Mode

### Nix in the operator pod

The operator image needs:
- Nix (single-user mode, no daemon)
- A writable `/nix/store` (PVC or ephemeral volume)
- Network access for fetching (git, Helm registries, Nix binary cache)
- `helm`, `kustomize`, `yq` for IFD derivations (or a binary cache
  that has them pre-built)

Image size: ~500MB (vs ~50MB for the current apply-only operator).
This is the main cost. Mitigation: two operator images, apply-only
(default) and eval-capable. The Activation CR's `source.type` determines
which is needed.

```
kix-operator:latest        — apply-only, ~50MB, OCI/storePath sources
kix-operator:eval          — eval-capable, ~500MB, git source
```

### Nix store management

The Nix store in the operator pod accumulates store paths across evals.
Without GC, it grows unbounded.

**GC strategy:**
- After each successful eval + deploy, GC all store paths not reachable
  from the current activation root or the previous activation root
  (keep one rollback generation).
- Use `nix store gc --max N` to cap total store size.
- The store PVC should be sized for ~2x the cluster's eval output
  (current + previous generation).

For a typical cluster (200 resources, ~50MB of manifests), the store
is small. For clusters with many IFD derivations (Helm charts, kustomize
bases), the store grows with the number of unique charts. 10GB PVC is
generous for most cases.

### Caching across evals

Nix's content-addressing provides natural caching. If only one package
changed, only its subgraph re-evaluates. IFD derivations (helm template,
kustomize build) are cached by their inputs — same chart + same values =
cache hit, no re-render.

A Nix binary cache (Cachix, self-hosted) dramatically speeds up eval
by providing pre-built derivations. The operator pulls from the cache
instead of building locally. This is the recommended setup for
production eval-mode operators.

### Eval isolation and resource limits

Nix eval is CPU-intensive and can be memory-hungry (large cluster
definitions with many IFD steps). The operator pod needs:

```yaml
resources:
  requests:
    cpu: "1"
    memory: "2Gi"
  limits:
    cpu: "4"
    memory: "8Gi"
```

Eval should be bounded by a timeout (default: 10 minutes). If eval
doesn't complete, the operator reports failure and retries with backoff.

For multi-tenant clusters where team fragments could contain expensive
Nix expressions, consider:
- Nix's `--max-eval-memory` flag
- Per-eval cgroup limits (if running eval as a subprocess)
- Eval sandboxing (Nix's sandbox mode is already on by default)

### Security: what can Nix eval do?

Nix eval in pure mode (`--pure-eval`) can:
- Read files within the flake closure (git repo)
- Evaluate Nix expressions
- Perform IFD (build derivations, read their output)

It cannot:
- Execute arbitrary commands (`builtins.exec` is disabled in pure eval)
- Read files outside the flake closure
- Access the network during eval (only during derivation builds, which
  are sandboxed)

IFD derivations (helm template, kustomize build) run in Nix's build
sandbox: no network (unless the derivation is a fixed-output derivation
like fetchHelmChart), no access to the host filesystem, no access to
the cluster API.

**The attack surface:** a compromised git repo can cause the operator to
build arbitrary Nix derivations. Fixed-output derivations (fetchHelmChart,
fetchKustomization) have network access but their output is hash-verified.
Non-fixed-output derivations (helmTemplateDerivation) are sandboxed with
no network. The main risk is resource exhaustion (infinitely recursive
Nix expression, derivation that fills disk) — bounded by the timeout
and resource limits above.

**Compared to Flux:** Flux runs `kustomize build` which can reference
arbitrary remote URLs, and `helm template` which can execute Lua
(Helm post-renderers). kix's Nix sandbox is arguably tighter.

---

## Fragment-Scoped Eval — Per-Team Autonomy

The most interesting capability of eval-in-cluster is per-team fragment
evaluation. This deserves deeper design.

### The model

```
infra-repo/
  flake.nix                        # defines evaluateCluster with fragment list
  clusters/production.nix          # platform team: namespaces, base config
  packages/                        # shared package library
  teams/
    backend/
      fragment.nix                 # backend team's instances + config
      packages/                    # team-specific packages (optional)
    frontend/
      fragment.nix
    data/
      fragment.nix
```

Each team pushes to their `teams/<name>/` directory. The operator detects
which paths changed (git diff between old and new ref) and knows which
fragments are affected. The full cluster still re-evals (because DI
resolution requires the complete picture — doc 01's core constraint), but
the operator can:

1. **Gate on path ownership.** Only allow the `backend` team's git
   identity to modify `teams/backend/`. Enforced via git branch
   protection + CODEOWNERS, or via the operator checking commit author
   against a team→path mapping.

2. **Scope blast radius reporting.** After eval, the operator reports:
   "backend team's push changed 3 resources in namespace `backend`."
   If a team's push causes changes outside their namespace (due to DI
   propagation), the operator can flag this for platform team review.

3. **Per-fragment approval policies.** Platform team changes require
   manual approval. Team-scoped changes (only affecting their namespace)
   auto-deploy. This is configured on the Activation CR:

```yaml
spec:
  fragments:
    - path: clusters/production.nix
      approvalRequired: true
      approvers: [platform-team]
    - path: teams/backend/
      approvalRequired: false
      scopeCheck: namespace:backend  # auto-deploy only if changes
                                      # are within this namespace
    - path: teams/data/
      approvalRequired: false
      scopeCheck: namespace:data
```

### Fragment isolation guarantees

The compile step enforces isolation. A team fragment can only:

- Instantiate packages from the shared library (or their team-specific
  packages, if allowed)
- Deploy to namespaces they're assigned to (enforced by the cluster
  definition — the platform team controls namespace assignment)
- Use DI to consume capabilities from other packages (read-only — they
  get the connection string, not the ability to modify the dependency)

A team **cannot**:
- Create resources in another team's namespace (the scope is locked
  to their assigned namespaces)
- Override another team's package config (fragment merging is per-namespace,
  not global — doc 01 Approach A)
- Bypass resource quotas (the platform team sets these in the base
  cluster definition, the module system enforces them with priority)
- Reference packages outside the approved library (the `availablePackages`
  filter controls this)

This is stronger than Flux's RBAC-based multi-tenancy. Flux checks
"can this service account create a Deployment in namespace X?" at apply
time. kix checks "does this team's fragment produce only valid resources
in namespace X?" at compile time — before anything touches the API server.

---

## The Two Modes Side by Side

| Property | OCI mode (doc 62) | Eval mode |
|---|---|---|
| **Operator image** | ~50MB, Rust binary only | ~500MB, Rust + Nix + tools |
| **Source** | OCI artifact from registry | Git repo (cloned in-cluster) |
| **Where eval runs** | Dev machine / CI | Operator pod |
| **Deploy latency** | CI queue + build + push + poll | Git poll + eval + apply |
| **Cluster credentials in CI** | No (CI pushes to OCI, not cluster) | No (cluster pulls from git) |
| **CI pipeline needed** | Yes (eval + push) | No (for deploy; still useful for tests/lint) |
| **Multi-cluster** | One OCI push per cluster (or shared artifact) | Each cluster pulls independently |
| **Team self-service** | Through CI | Direct git push → deploy |
| **Binary cache benefit** | Speeds up CI eval | Speeds up in-cluster eval (critical for IFD) |
| **Nix store management** | Dev/CI responsibility | Operator GC (new concern) |
| **Reproducibility** | Eval output is pre-computed, deterministic | Eval output is deterministic from git ref (but needs Nix in-cluster to reproduce) |
| **Offline clusters** | Works (OCI artifact is self-contained) | Doesn't work (needs git + cache access) |
| **Debugging** | `nix eval` locally, compare against OCI artifact | `nix eval` locally, compare against operator's eval (same result if same ref) |

### When to use which

**OCI mode (default):**
- Air-gapped / offline clusters (doc 47)
- Clusters where you don't want Nix installed
- Regulated environments requiring artifact signing (doc 54)
- Simple setups with one or few clusters

**Eval mode:**
- Platform teams iterating frequently on cluster config
- Multi-cluster fleets (10+ clusters from same repo)
- Teams that want self-service deploy without CI
- Development / staging clusters where deploy speed matters
- Organizations already running Nix binary caches

**Both modes simultaneously:** A production cluster uses OCI mode (artifact
signing, air-gapped capable, minimal operator). A staging cluster uses eval
mode (fast iteration, team self-service). Same repo, same packages, same
compile-time guarantees — different deployment path.

---

## Job Submission Protocol

The compiled ad-hoc compute capability (§5 above) needs a concrete protocol.

### Option A: Git-based job submission

Teams commit job definitions to their fragment directory. The operator
picks them up on the next eval cycle.

```
teams/data/
  fragment.nix
  jobs/
    backfill-2026-04.nix    # team adds this file, pushes
```

The fragment's `fragment.nix` auto-discovers jobs:

```nix
# teams/data/fragment.nix
{ lib, packages, ... }:
let
  jobFiles = lib.filesystem.listFilesRecursive ./jobs;
  jobPackages = map (f: import f) jobFiles;
in
{
  instances.data = builtins.listToAttrs (
    map (j: { name = j.meta.name; value = { package = j; }; }) jobPackages
  );
}
```

**Advantages:** Pure git workflow. Jobs get the same review/approval
process as any other change. Full audit trail.

**Disadvantages:** Not instant — waits for poll interval. Commit per job
is noisy. Completed jobs linger until someone removes the file.

### Option B: CRD-based job submission

A `KixJob` CRD that the operator watches:

```yaml
apiVersion: kix.dev/v1alpha1
kind: KixJob
metadata:
  name: backfill-2026-04
  namespace: data
spec:
  # Inline Nix expression or git ref to a .nix file
  source:
    type: inline
    expression: |
      { scope, lib }:
      {
        build = { self, ... }:
          let
            db = self.deps.postgres;
            job = scope.mkJob {
              name = "backfill-2026-04";
              containers.backfill = {
                image = "data-team/backfill:v3";
                env.DATABASE_URL = db.out.connectionString;
              };
            };
          in { root.resource = job; };
      }
  # Or reference a file in the repo
  # source:
  #   type: gitFile
  #   path: teams/data/jobs/backfill-2026-04.nix

  # Compile-time DI context
  clusterContext: production  # which cluster's DI graph to compile against
  namespace: data             # scope constraint

status:
  phase: Compiled | Running | Succeeded | Failed
  compiledResources: 3  # Job + ServiceAccount + RoleBinding
  startTime: "2026-04-10T14:00:00Z"
```

The operator:
1. Watches `KixJob` CRs
2. On create: evals the Nix expression within the cluster's DI context
3. Applies the compiled resources (Job + auto-generated RBAC + NetworkPolicy)
4. Watches the Job's status
5. On completion: reports status, optionally cleans up resources

**Advantages:** Instant submission. No git commit needed. Status tracking
via standard K8s status. Familiar CRD workflow.

**Disadvantages:** Inline Nix in a YAML CRD is ugly. Security: who can
create `KixJob` CRs? Need RBAC scoping. The Nix expression is mutable
cluster state, not git-tracked (lose reproducibility unless `gitFile`
source is used).

### Recommendation

**Option A for production, Option B for development.** Production jobs
should be git-tracked (audit trail, review, reproducibility). Development
jobs benefit from instant submission. The operator supports both — the
`KixJob` CRD is sugar over "eval this expression in the cluster's DI
context."

---

## Live Compiler Passes — Right-Sizing and Beyond

Pure eval is deterministic from git: same code, same output, regardless
of where or when you eval. This is the foundation. But the eval operator
has something no CI pipeline has: **live access to the cluster it's
deploying to.** This enables a second category of compiler passes that
run *after* pure eval, informed by runtime data.

### The pipeline

```
git repo
  ↓
nix eval (pure, deterministic)
  ↓
DAG with declared resource values          ← "intent"
  ↓
live compiler passes (cluster-aware)
  ↓
adjusted DAG with operational values       ← "operational reality"
  ↓
DIFF → PLAN → APPLY → PRUNE
```

The pure eval produces the team's **intent** — what they declared in Nix.
The live passes adjust the output based on what's actually happening on
the cluster. The key architectural rule: **live passes are a separate,
auditable layer.** The pure eval output is always available as the
baseline. Every live adjustment is tracked as a delta, so you can always
answer "what did the team declare vs what did the operator deploy?"

### What live passes can do

#### 1. Resource right-sizing

The most obvious application. Teams declare resource requests/limits in
their package config. The operator knows actual usage from metrics.

**Data source:** Prometheus (via PromQL) or metrics-server (via K8s
metrics API). The operator queries historical usage for each workload.

**What it adjusts:**

```
Declared:  resources.requests.memory = "4Gi"
Observed:  p99 memory usage over 7 days = 812Mi
Adjusted:  resources.requests.memory = "1Gi"  (p99 * 1.25 safety margin)
```

The adjustment logic:

```nix
# In the package or cluster config — the team declares the POLICY,
# not the exact value
options.resources = {
  mode = lib.mkOption {
    type = lib.types.enum [ "declared" "auto" "bounded-auto" ];
    default = "declared";
    description = ''
      "declared" — use exact values from config (pure eval, no live pass)
      "auto" — operator right-sizes based on metrics
      "bounded-auto" — operator right-sizes within declared bounds
    '';
  };

  # Only used in bounded-auto mode
  bounds = {
    memory = { min = "256Mi"; max = "8Gi"; };
    cpu = { min = "100m"; max = "4"; };
  };
};
```

Three modes reflecting different trust levels:

| Mode | Pure eval output | Live pass adjustment | Who controls |
|---|---|---|---|
| `declared` | Exact values from config | None | Team (full control) |
| `auto` | Values are placeholders | Operator replaces from metrics | Operator (full autonomy) |
| `bounded-auto` | Bounds from config | Operator picks within bounds | Shared (team sets guardrails, operator optimizes) |

`bounded-auto` is the sweet spot for most teams: "I know my app needs
at least 256Mi and shouldn't exceed 8Gi, but I don't know the right
value — the operator does."

#### 2. Replica count tuning

Similar to right-sizing but for horizontal scale. The team declares a
scaling policy, the operator adjusts replica count based on actual load.

```nix
options.scaling = {
  mode = lib.mkOption {
    type = lib.types.enum [ "fixed" "auto" ];
    default = "fixed";
  };
  minReplicas = lib.mkOption { type = lib.types.int; default = 1; };
  maxReplicas = lib.mkOption { type = lib.types.int; default = 10; };
  targetCPUUtilization = lib.mkOption { type = lib.types.int; default = 70; };
};
```

In `fixed` mode, pure eval sets `spec.replicas` directly. In `auto`
mode, the live pass calculates the right replica count from current CPU
utilization and sets it. This is HPA-like behavior but integrated into
the compile step — the operator produces a Deployment with a concrete
replica count, not a Deployment + HPA. The advantage: the replica count
participates in the DAG (resource quota validation, PDB tuning, etc.).

**Note:** this doesn't replace HPA for workloads that need sub-minute
scaling. It's for workloads where "eval every 5 minutes and adjust" is
fast enough — which covers most non-latency-critical services.

#### 3. PDB tuning

A PodDisruptionBudget's `minAvailable` should reflect actual replica
count and failure domain topology. The live pass can:

- Set `minAvailable` to `replicas - 1` (or a percentage) based on
  actual running replicas
- Account for failure domains: if pods are spread across 3 AZs, PDB
  can tolerate losing one AZ's worth of pods

#### 4. Storage sizing

PVC sizes are notoriously hard to get right at declaration time. The
live pass can:

- Monitor actual disk usage growth rate via Prometheus
- Project when the current PVC will fill up
- Emit a diagnostic warning ("PVC `data-postgres` is 78% full, projected
  to fill in 12 days at current growth rate")
- Optionally auto-resize (for storage classes that support it) by
  adjusting `spec.resources.requests.storage`

#### 5. Node affinity / topology hints

The operator knows the cluster's actual node topology (labels, taints,
capacity, failure domains). The live pass can:

- Add `topologySpreadConstraints` based on actual zone layout
- Set `nodeAffinity` to prefer nodes with available capacity
- Warn when a workload's resource requests can't be satisfied by any
  node ("Deployment `gpu-worker` requests `nvidia.com/gpu: 4` but no
  node has more than 2 available")

#### 6. Image availability validation

The operator can check whether container images referenced in the eval
output actually exist in the registry. This catches:

- Typos in image tags
- Images that were deleted from the registry
- Tags that haven't been pushed yet (team pushed cluster config before
  CI finished building the image)

This is a read-only diagnostic — it doesn't change the output, it
warns before applying.

### The purity question

**Live passes break reproducibility.** Same git code + different cluster
state = different deployed manifests. This is intentional and bounded:

1. **The pure eval output is always preserved.** The Activation CR
   stores both the pure eval hash and the post-adjustment hash. `kix diff`
   can show either. Rollback targets the pure output (known-good from git),
   not the adjusted output.

2. **Adjustments are scoped to opt-in resources.** Only resources whose
   packages declare `mode = "auto"` or `mode = "bounded-auto"` are
   touched. Everything else passes through unchanged. A cluster where
   no package opts in behaves identically to OCI mode.

3. **Every adjustment is logged as a structured delta.** The operator
   records: resource X, field Y, pure value A, adjusted value B, reason
   "p99 memory over 7d was Z." This is auditable.

4. **Bounds are compile-time guarantees.** In `bounded-auto` mode, the
   live pass cannot set values outside the declared bounds. The bounds
   are part of the pure eval output — they're git-controlled. The
   operator has autonomy *within* the policy the team defined.

The mental model: **pure eval defines the policy, live passes execute
the policy.** The team says "memory should be between 256Mi and 8Gi,
pick the right value." The operator picks. The team doesn't lose
control — they lose the need to manually tune.

### Architecture: where live passes run

```
                    ┌─────────────────────────┐
                    │    Eval Operator Pod     │
                    ├─────────────────────────┤
                    │                         │
  git ──────────────►  nix eval (pure)        │
                    │      ↓                  │
                    │  pure DAG               │
                    │      ↓                  │
  K8s API ─────────►  live pass: validate     │  ← CRD existence, image checks
  metrics-server ──►  live pass: right-size   │  ← resource requests/limits
  prometheus ──────►  live pass: scale        │  ← replica count
                    │      ↓                  │
                    │  adjusted DAG           │
                    │      ↓                  │
                    │  apply engine           │
                    │  (unchanged)            │
                    └─────────────────────────┘
```

Live passes are a pipeline of functions:
`DAG → (DAG, diagnostics)`. Each pass reads from a data source,
applies adjustments (within declared policy), and emits diagnostics.
Passes are independent and composable — you can run right-sizing
without replica tuning, or both, or neither.

The pass pipeline is configured on the Activation CR:

```yaml
spec:
  livePasses:
    rightSizing:
      enabled: true
      metricsSource: prometheus
      prometheusUrl: http://prometheus.monitoring:9090
      lookbackWindow: 7d
      safetyMargin: 1.25
    replicaTuning:
      enabled: false
    validation:
      enabled: true
      checkImages: true
      checkCRDs: true
      checkNodeCapacity: true
```

### Advisory mode — live passes without adjustment

For teams that want the insights but not the auto-adjustment, live
passes can run in **advisory mode**: they compute what they *would*
change but only emit diagnostics (doc 80), never modify the DAG.

```yaml
spec:
  livePasses:
    rightSizing:
      enabled: true
      mode: advisory  # "adjust" (default) or "advisory"
```

Advisory mode output in `kix diff` / TUI:

```
[advisory] Deployment backend/api:
  resources.requests.memory: declared 4Gi, recommended 1Gi
    (p99 usage over 7d: 812Mi, safety margin: 1.25x)
  resources.requests.cpu: declared 2, recommended 500m
    (p95 usage over 7d: 380m, safety margin: 1.3x)
  estimated savings: 3Gi memory, 1.5 CPU per replica (3 replicas = 9Gi, 4.5 CPU)
```

This is useful for teams migrating from `declared` to `bounded-auto` —
they can see what the operator would do before trusting it.

### Interaction with the scorecard (doc 60)

Right-sizing data feeds naturally into the scorecard framework. A
scorecard rule can flag:

- Resources with >2x overprovisioning (declared vs actual usage)
- Resources with <1.1x headroom (risk of OOM / throttling)
- PVCs with <20% free space
- Workloads with no resource limits set

These rules are advisory-only in pure eval mode (no metrics available)
but become data-backed in eval operator mode. The scorecard output
shifts from "you didn't set resource limits" (static lint) to "you set
4Gi but you're using 800Mi" (live analysis).

---

## Interaction with Existing Docs

**Doc 43 (Activation Operator):** Already sketches `type: git` source.
Eval mode is the full realization of that sketch. The control loop
(RESOLVE → DIFF → PLAN → APPLY → PRUNE) is unchanged — eval mode only
changes the RESOLVE step.

**Doc 62 (Operator Production Plan):** Eval mode is a new phase after
Phase 3 (operational hardening). It requires a separate operator image
and Nix store management. OCI mode remains the Phase 1-3 target.

**Doc 01 (Cluster Merging):** Fragment-scoped eval depends on cluster
merging being implemented. The merge-before-fixpoint design is exactly
what makes per-team fragments safe — the fixpoint sees all fragments and
validates cross-team DI.

**Doc 36 (Rust Oracle):** The oracle's value increases in eval mode.
In-cluster eval means the oracle could optionally access the K8s API for
read-only validation (CRD existence, node capacity, storage class
validation). This must remain advisory — the eval output depends only on
git, not on cluster state.

**Doc 88b (Flux Comparison):** Eval mode closes the three Flux advantages
that kix currently doesn't match: pull model, no-CI deploy, multi-cluster
without fan-out. It also opens advantages Flux can't match: compiled DI
for jobs, typed fragment isolation, compile-time cross-team validation.

**Doc 59 (Load Estimation):** Load estimation from the DI graph is a
pure-eval feature. Live passes complement it: doc 59 estimates load from
declared consumer demand (compile-time), live passes adjust from actual
measured demand (runtime). The two compose — doc 59's estimate is the
starting point, live right-sizing refines it over time.

**Doc 60 (Scorecard Rules):** Scorecard rules gain data-backed severity
in eval mode. Static rules ("no resource limits set") become live rules
("resource limits are 5x actual usage"). The scorecard output becomes
actionable rather than aspirational.

---

## Open Questions

### 1. Eval reproducibility across environments

If the operator evals at git ref `abc123` and produces DAG hash `X`, a
developer running `nix eval` at the same ref should produce the same
hash. This is guaranteed by Nix's purity — same inputs, same outputs.

But: different Nix versions, different system architectures (`x86_64`
vs `aarch64`), or different `nixpkgs` pins could produce different
results. Mitigation: the flake pins everything (Nix version via
`nix.conf` in the flake, nixpkgs via flake input, system via
`builtins.currentSystem`). The operator's Nix version must match the
flake's expectation.

### 2. Webhook vs polling

Polling at a fixed interval (default 5m) is simple but has latency.
A webhook from GitHub/GitLab can trigger immediate eval. The operator
should support both — a `/webhook` endpoint that triggers eval on push,
with polling as fallback.

### 3. Concurrent evals

If two pushes arrive in quick succession, should the operator:
- (a) Queue and eval sequentially (simple, no races)
- (b) Cancel the in-progress eval and start fresh (fast convergence)
- (c) Eval both and apply only the later one (wasteful but correct)

Leaning toward (b) — cancel stale eval, start new. The latest git ref
is always the desired state. Wasted eval work is bounded by the timeout.

### 4. Partial eval / incremental compilation

Full cluster eval on every push is wasteful if only one team's fragment
changed. Can we eval incrementally?

Nix doesn't support incremental evaluation natively. But:
- Nix caches derivation outputs by their inputs. Unchanged IFD
  derivations (helm template, kustomize build) are cache hits.
- The fixpoint must run over all fragments (doc 01 constraint), but
  most of the computation is lazy — unchanged fragments produce the
  same thunks, which Nix short-circuits.

In practice, a re-eval where one package changed takes ~5-10s (warm
cache) vs ~30-60s (cold). The Nix store cache on the operator's PVC
provides warm-cache performance for most evals.

True incremental eval would require Nix-level changes (incremental
fixpoint computation). Not worth pursuing — the caching story is good
enough.

### 5. Fallback on eval failure

If eval fails (syntax error in a team's fragment, broken IFD derivation),
the operator should:
- **Not touch the cluster.** The current activation remains active.
- **Report the error** via Activation status and/or notification.
- **Retry on next push** (the team fixes their fragment and pushes again).
- **Not block other teams.** If fragment-scoped eval is supported, only
  the broken team's changes are blocked. (But because of the fixpoint
  constraint, a broken fragment breaks the whole eval. This is a real
  problem — see §Fragment isolation below.)

**Fragment isolation for eval failures:** A syntax error in team A's
fragment prevents team B's changes from deploying. This is the cost
of the shared fixpoint. Mitigations:
- **Pre-push validation.** Teams run `nix eval` locally before pushing.
  CI lint catches most errors. The operator is the last line, not the
  first.
- **Fragment-level caching.** The operator caches the last known-good
  version of each fragment. If a fragment fails to parse, fall back to
  the cached version and eval with the rest. Report a warning.
- **Branch-per-team with merge eval.** Each team pushes to their own
  branch. The operator merges all team branches + main before eval. A
  broken team branch is excluded from the merge (operator evals
  `main + all healthy team branches`). This gives per-team isolation
  without breaking the shared fixpoint.

### 6. KixJob security model

Who can submit `KixJob` CRs? Options:
- (a) Same RBAC as creating Pods in the target namespace. If you can run
  a Pod, you can run a KixJob (which creates Pods).
- (b) Separate RBAC role: `kixjobs.kix.dev/create`. More restrictive —
  the platform team controls who can submit compiled jobs.
- (c) Only from git (Option A). No CRD-based submission in production.

Leaning toward (b) for production + (a) for dev clusters, with (c) as
a hardened option for regulated environments.
