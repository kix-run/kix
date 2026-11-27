# Demo Plan: Full Lifecycle (CLI + Operator)

## Working Document — March 2026

**Status:** Planning
**Format:** VHS-recorded GIF demos (two tapes: CLI direct mode, operator mode)
**Cluster:** `test-kind` on a local kind cluster (`kind-kix-demo`)

---

## 1. What We Demonstrate

This demo tells a single story in two modes (CLI direct, operator-driven):

> "Here is a cluster. We deploy it. It's healthy. We change something. We deploy the change — here's exactly what changed and why. We break something on purpose. The system tells us what's wrong and what's affected. We fix it. We roll back."

The narrative proves five things about kix:

1. **Deterministic deployment** — wave-ordered, dependency-aware, with a clear plan before anything touches the cluster
2. **Full observability** — health, drift detection, blast radius, package-level status at any point
3. **Safe changes** — the diff shows exactly what will change, grouped by package, before you confirm
4. **Self-healing awareness** — when something is wrong, kix tells you *what*, *where*, and *what else is affected*
5. **Instant rollback** — no rebuild, pointer swap to a previous known-good state

---

## 2. Demo Cluster Design

### Cluster: `test-kind` (v1 → v2)

We use two cluster definitions to simulate a configuration change:

**`clusters/test-kind.nix`** (v1 — initial deploy):
- Namespace: `echo`
- Packages: `echo-server` with `message = "hello from kix on kind!"`
- Resources: ConfigMap → Deployment (mounts ConfigMap) → Service
- This gives us a 3-resource dependency chain within one package

**`clusters/test-kind-v2.nix`** (v2 — the change):
- Same structure, but:
  - `message = "hello from kix v2 — updated!"` (ConfigMap content changes)
  - `replicaCount = 2` (Deployment spec changes)
- This triggers: ConfigMap hash change → Deployment hash change (new content + new replica count + volume ref changed) → Service hash change (selector/dependency)
- The plan should clearly show "echo-server: 3 resources modified" with the specific diffs

### Why This Works for the Demo

- **Minimal** — runs on vanilla kind, no CRDs/storage/ingress needed
- **Has real dependencies** — ConfigMap → Deployment → Service chain is visible in the graph
- **Change propagation is visible** — changing the message cascades through the DAG
- **Blast radius is meaningful** — deleting the ConfigMap affects the Deployment (mount broken) and transitively the Service

### Future Enhancement (not this demo)

For a richer demo with cross-package dependencies (DI, auto-instantiation, multi-namespace), use the `example` cluster or build a demo-specific cluster with coredns + echo-server + a second app that depends on coredns. This would show inter-package blast radius and wave ordering across packages.

---

## 3. CLI Demo Tape — Scene by Scene

### Scene 1: Orientation (what clusters exist, what's in them)

```
# kix — Nix-native Kubernetes deployment
# CLI direct mode: deploy, change, break, heal, rollback

kix list
kix inspect kind
kix graph kind
```

**What the viewer sees:** Available clusters, packages with their DI wiring, the dependency DAG as a tree.

**Why this matters:** Before touching anything, you can see the full picture — what will be deployed, how it's wired, what depends on what.

---

### Scene 2: First deploy (v1)

```
kix --context kind-kix-demo deploy kind --yes
```

**What the viewer sees:**
- The build (nix eval)
- The plan: "echo-server: 3 resources to create" with the list
- Wave-by-wave apply (ConfigMap first, then Deployment, then Service)
- Readiness checks passing
- Activation finalized

**Why this matters:** Deployment is ordered by the dependency graph. Resources are created in the right order. Everything waits for readiness before proceeding.

---

### Scene 3: Health check — everything is healthy

```
kix --context kind-kix-demo health kind
```

**What the viewer sees:**
- Graph traversal from activation root
- All resources: in-sync
- Package summary: `echo-server ✓ (3/3 resources healthy)`
- Exit code 0

**Why this matters:** The system can verify its own state. Content hashes match. No drift.

---

### Scene 4: Status — live cluster state

```
kix --context kind-kix-demo status kind
```

**What the viewer sees:** Table of all managed resources with ready/not-ready status, replica counts, age.

---

### Scene 5: Deploy v2 — the change

We swap to the v2 cluster definition and deploy again.

```
# Switch to v2 cluster definition
cp clusters/test-kind-v2.nix clusters/test-kind.nix

kix --context kind-kix-demo deploy kind
```

**What the viewer sees:**
- The plan, showing package-level diff:
  - `echo-server: 3 resources modified`
  - ConfigMap: `message` field changed
  - Deployment: `replicas` changed (1 → 2), volume hash reference updated
  - Service: dependency hash updated
- Interactive confirmation prompt → user confirms
- Wave-by-wave apply
- Readiness: waits for 2/2 replicas ready

**Why this matters:** The diff is precise. You see exactly what changed and why. The deployment only touches what needs to change. The plan groups changes by package so you understand the blast radius of your change *before* it happens.

---

### Scene 6: Health + GC after v2 — still healthy, no garbage

```
kix --context kind-kix-demo health kind
kix --context kind-kix-demo gc kind --yes
```

**What the viewer sees:** All healthy. GC finds nothing to collect (the old resources were updated in-place via SSA, not orphaned).

---

### Scene 7: Break something — delete a resource

```
kubectl --context kind-kix-demo delete configmap <configmap-name> -n echo
```

**What the viewer sees:** The ConfigMap is gone.

---

### Scene 8: Health check detects the problem

```
kix --context kind-kix-demo health kind -v
```

**What the viewer sees:**
- Graph traversal: hits the missing ConfigMap
- `echo-server: DEGRADED`
  - `ConfigMap echo-server-config: MISSING`
  - `Deployment echo-server: AT RISK` (depends on missing ConfigMap)
  - `Service echo-server: AT RISK` (depends on at-risk Deployment)
- Blast radius summary: "1 missing, 2 at risk, 1 package degraded"

**Why this matters:** The health check doesn't just say "a resource is missing." It tells you *what's affected* by walking the dependency graph forward from the broken resource. The Deployment mounts that ConfigMap — if the pod restarts, it will fail. The Service routes to that Deployment. The whole package is degraded.

---

### Scene 9: Watch mode (brief)

```
watch -n2 kix --context kind-kix-demo health kind
```

**What the viewer sees:** The health output refreshing every 2 seconds, showing the degraded state persisting. (Brief — just to show it works with `watch`.)

---

### Scene 10: Re-deploy to fix

```
kix --context kind-kix-demo deploy kind --yes
```

**What the viewer sees:**
- Plan: "echo-server: 1 resource to re-create" (the ConfigMap)
- The ConfigMap is re-applied
- Health returns to all-green

---

### Scene 11: Rollback

```
kix --context kind-kix-demo rollback kind --yes
```

**What the viewer sees:**
- "Rolling back to activation <hash> (deployed at <timestamp>)"
- Plan: shows the reverse diff (v2 → v1)
  - ConfigMap: message reverts
  - Deployment: replicas 2 → 1
- Wave-by-wave apply
- Activation lifecycle: current marked Superseded, previous marked Active

**Why this matters:** Rollback doesn't rebuild anything. It uses the cached store path from the previous deployment. The diff shows exactly what rolling back will change.

---

### Scene 12: Final health check

```
kix --context kind-kix-demo health kind
```

**What the viewer sees:** All healthy, back to v1 state.

```
# Done! Full lifecycle: deploy → change → break → detect → fix → rollback
```

---

## 4. Operator Demo Tape — Scene by Scene

The operator demo shows the same lifecycle but driven by Activation CRs instead of CLI commands.

### Setup (handled by run-demos.sh, not in tape)

- kind cluster created
- CRDs applied (Activation, PackageInstance)
- kix-operator started in background
- Nix activation built (`nix build .#cluster-kind-activation`)

### Scene 1: Orientation

```
# kix operator — Kubernetes-native reconciliation
kubectl --context kind-kix-demo get crd | grep kix
ps aux | grep kix-operator | grep -v grep | head -1
```

### Scene 2: Deploy via Activation CR

```
cat demo/vhs/activation-cr.yaml
kubectl --context kind-kix-demo apply -f demo/vhs/activation-cr.yaml
```

Then poll/watch resources appearing:
```
watch -n2 kubectl --context kind-kix-demo get all,configmap -n echo -l app.kubernetes.io/managed-by=kix
```

**What the viewer sees:** Resources appearing wave-by-wave as the operator reconciles.

### Scene 3: Verify + health

```
kubectl --context kind-kix-demo get activations.kix.dev -o wide
kix --context kind-kix-demo health kind
```

### Scene 4: Update — apply v2 Activation CR

```
# Update the Activation CR to point to v2 store path
kubectl --context kind-kix-demo apply -f demo/vhs/activation-cr-v2.yaml
```

**What the viewer sees:** The operator detects the change, computes a diff, and reconciles. Resources update wave-by-wave. (Operator logs visible in a side terminal or via `kubectl logs` if we run the operator as a pod.)

### Scene 5: Break something + operator self-heals

```
kubectl --context kind-kix-demo delete configmap <name> -n echo
```

**What the viewer sees:** The operator's next reconcile loop (300s, or we can trigger it) detects the missing resource and re-applies it. Health check shows brief degraded state, then recovery.

**Note:** The operator's default requeue interval is 300s. For the demo, we may want to either:
- Shorten this to ~30s for the demo cluster
- Manually trigger reconciliation by touching the Activation CR annotation
- Accept the wait and fast-forward in the VHS tape

### Scene 6: Rollback via old Activation CR

```
# Apply the original activation CR (v1 store path)
kubectl --context kind-kix-demo apply -f demo/vhs/activation-cr.yaml
```

**What the viewer sees:** Operator picks up the change, reconciles back to v1 state.

### Scene 7: Cleanup via deletion

```
kubectl --context kind-kix-demo delete activation.kix.dev demo-activation --timeout=60s
kubectl --context kind-kix-demo get all,configmap -n echo -l app.kubernetes.io/managed-by=kix --ignore-not-found
```

**What the viewer sees:** Finalizer triggers reverse-order deletion of all managed resources.

---

## 5. Technical Requirements

### Cluster definitions needed

| File | Purpose |
|---|---|
| `clusters/test-kind.nix` | v1 — base echo-server deployment |
| `clusters/test-kind-v2.nix` | v2 — changed message + replicas |

The v1/v2 swap is done by `cp` in the CLI tape (simulating "I edited my cluster"). For the operator tape, two separate Activation CRs with different store paths.

### VHS tape structure

| Tape | Estimated duration | Output |
|---|---|---|
| `demo/vhs/cli-demo.tape` | ~3-4 min | `cli-demo.gif` |
| `demo/vhs/operator-demo.tape` | ~3-4 min | `operator-demo.gif` |

### run-demos.sh changes

- Build both v1 and v2 activations
- Generate two Activation CR YAMLs (v1 and v2 store paths)
- Handle the `cp` swap for CLI tape
- Restore original `test-kind.nix` on cleanup

### Features needed (see 52_demo_implementation_todo.md)

- Health check: package-level grouping
- Health check: blast radius (graph-forward from broken resources)
- Health check: verbose mode with graph traversal output
- `test-kind-v2.nix` cluster definition

---

## 6. Open Questions / Future Ideas

- **Live-edit variant:** For a live (non-VHS) demo, editing the `.nix` file on camera is more compelling than `cp`. Could use `sed` or a prepared edit. Note for future live demos.
- **k9s split screen:** Running `k9s` alongside the CLI demo would show resources appearing/disappearing in real time. Requires terminal multiplexing in VHS or a separate recording approach.
- **Operator logs panel:** Showing operator logs alongside the resource changes would make the reconciliation loop more visible. Could use a split terminal.
- **Richer cluster:** A multi-package cluster with DI (e.g., coredns + app depending on it) would make blast radius more dramatic. Planned for a future iteration.
- **Network policy derivation demo:** Once implemented, showing auto-generated NetworkPolicies from the dependency graph would be a strong compiler demo.

---

## 7. Demo Catalog

Beyond the lifecycle demo above, these are the other demos we could build, organized by implementation readiness. (Consolidated from earlier brainstorming in doc 53.)

### Tier 1: Ready Today (or with minor work)

**1.2 Package Authoring — "How to Write a kix Package"**
- Audience: Package authors, developers evaluating kix
- Story: Start from scratch, build an echo-server package step by step
- Shows: Package anatomy (`meta`, `options`, `build`), `scope.mkResource`/`scope.mkDeployment`, `self.configmap.out.name` dependency tracking, pipe composition (`|> kix.service.fromWorkload`), `kix inspect`/`kix graph`/`kix build`
- Format: VHS tape that "types out" the nix file, or side-by-side (nix code on left, YAML on right)

**1.3 Cluster Definition — "How to Wire a Cluster"**
- Audience: Cluster operators, platform teams
- Shows: `kix.buildCluster` with modules, namespace + instance declarations, config overrides, DI resolution, flavors
- Implementation: Use the `example` cluster definition (coredns + valkey + cert-manager + immich)

**1.4 Diff Deep-Dive**
- Audience: Change management / PR review
- Shows: `kix diff kind`, build-to-build comparison, package-grouped output, keyed-list-aware diffing, rename detection, CI exit codes
- Implementation: Ready today

**1.5 Dependency Graph Visualization**
- Audience: Universal
- Shows: `kix graph kind --format tree/dot/json`, graphviz SVG rendering, content-address-derived edges
- Implementation: Ready today

**1.6 Snapshot + Offline Diff**
- Audience: CI/CD, audit teams
- Shows: `kix snapshot save/diff`, offline change detection without cluster access, CI integration
- Implementation: Ready today

### Tier 2: Needs Moderate Work

**2.1 Auto-Instantiation** — App declares postgres dependency, kix auto-creates it. Demo: `test-auto` cluster.

**2.2 DI-Driven Defaults** — Add ingress controller → all apps get ingresses. Remove it → graceful degradation. Demo: example cluster with/without cert-manager.

**2.3 Content-Addressing Explained** — Change one ConfigMap value, watch the hash cascade through the DAG. Shows determinism + blast radius.

**2.4 Hardware Flavors** — Same cluster definition, different flavors (kind, k3s, hetzner). Build-to-build diffs show manifest differences.

**2.5 Security Defaults** — Non-root by default via `mkDefault`; overrides require `mkForce` (greppable, auditable). Needs implementation (ROADMAP item).

**2.6 Network Policy Derivation** — NetworkPolicies auto-derived from dependency graph. `lib/netpol.nix` exists; needs demo cluster with Cilium on kind.

### Tier 3: Needs Significant Work

- **Compiler errors** — Missing dependency, version incompatibility, extension mismatch, cross-namespace violation. Refs: `29_compiler-design.md` sections 3-5.
- **CRD Schema Validation** — Typo in cert-manager CR caught at build time. `mkCRD` has schemas; `mkCR` needs validation pass.
- **Connection Graph + Port Fan-Out** — Typed connection edges → derived env vars, network policies, port validation. Ref: `29_compiler-design.md` 4.1-4.3.
- **Whole-Cluster Analysis** — Selector uniqueness, port conflicts, quota fit. Ref: `29_compiler-design.md` section 5.
- **PR Preview Environments** — Content-addressing means unchanged services share resources. Needs multi-activation support.
- **Canary / Wave Rollouts** — Different hash = different resource = side-by-side. Needs traffic management integration.
- **Vertical Integration** — Rust source → Nix binary → container image → running pod. Needs nix-snapshotter.
- **Air-Gapped Deployment** — `nix copy --to`, no downloads during deploy. Ref: `47_air_gapped_deploys.md`.

### Tier 4: Aspirational

- Topology-aware monitoring (auto-generated dashboards from dep graph)
- Cross-cluster comparison (staging vs prod hash divergence)
- "What if" analysis (upgrade impact preview)
- Functional CRDs (compile-time operator replacement)
- Local dev loop (Tilt-inspired watch + rebuild)
- Supply chain audit (Merkle DAG walk, cryptographic verification)

---

## 8. Planned Demo: "The Compiler Catches Everything" (VHS Tape)

**Audience:** Platform engineers, technical decision-makers
**Format:** Single VHS tape, ~3-5 min, continuous narrative
**Protagonist:** Immich (real app, real postgres+pgvecto.rs dependency)
**One-line:** Missing → wrong → automatic → governed → composable → traceable — all at build time.

**Scene 1 — Missing DI:** Cluster with immich but no postgres → build-time error.

**Scene 2 — Wrong Usage:** Add postgres without pgvecto.rs → build-time error (immich requires it).

**Scene 3 — Auto-Configuration:** Leave postgres unlocked. Immich's DI auto-configures postgres with right extensions. `kix inspect` + `kix graph` show the result. Variant: remove explicit postgres, enable auto-instantiation.

**Scene 4 — Locked Fields Enforce Team Boundaries:** Platform team locks `extensions` with `mkLocked`. Immich's DI injection blocked → build-time error. Team governance at build time.

**Scene 5 — DI-Driven Defaults Compose:** Unlock postgres, add cert-manager. `kix diff` shows immich now has TLS annotations + Certificate CR. No one edited immich's config.

**Scene 6 — Content-Addressing Reveals Blast Radius:** Change postgres `max_connections`. Diff shows postgres + immich get new hashes. Cert-manager untouched. Blast radius computed, not guessed.

**Closing:** Six scenarios, zero cluster access. Every mistake caught, every dependency resolved, every boundary enforced — all before a single manifest reaches the API server.

---

## 9. Demo Packaging Strategy

### Format options
- **VHS GIF** — current approach, good for README/website, self-contained
- **Asciinema** — terminal recording with copy-paste support, better for tutorials
- **Live demo** — most compelling for talks/meetings, riskiest
- **Side-by-side** — nix code on left, resulting resources on right (for package authoring)
- **Split terminal** — k9s or operator logs alongside CLI (for lifecycle demos)

### Progressive complexity
Demos should be watchable in order, each building on the previous:
1. "What does kix produce?" (build + inspect)
2. "How do I deploy?" (deploy + health)
3. "How do I write a package?" (package authoring)
4. "How do I wire a cluster?" (cluster definition)
5. "What happens when things break?" (lifecycle demo)
6. "What does the compiler catch?" (build-time errors)
7. "Where is this going?" (vision demos)

### Demo index page
A simple page (or README section) linking to all available demos with one-line descriptions and estimated duration.
