# Demo Brainstorm — All Possible Demos

## Working Document — March 2026

**Status:** Brainstorm
**Context:** Catalog of demos we *could* build, ranging from "ready today" to "needs major features first." Ordered roughly by implementation readiness, then by audience impact.

---

## Tier 1: Ready Today (or with minor work)

These use existing CLI commands and packages with at most small changes.

### 1.1 Full Lifecycle Demo (CLI + Operator)

**Audience:** Platform engineers, DevOps, investors
**Story:** Deploy → change → break → detect → fix → rollback
**What it shows:** Deterministic deploy, health/drift detection, blast radius, rollback
**Status:** Planned — see `51_demo_plan.md`

### 1.2 Package Authoring — "How to Write a kix Package"

**Audience:** Package authors, developers evaluating kix
**Story:** Start from scratch, build an echo-server package step by step
**What it shows:**
- Package anatomy: `meta`, `options`, `build`
- `scope.mkResource`, `scope.mkDeployment` — resources as rich objects
- `self.configmap.out.name` — dependency tracking via interpolation
- `|> kix.service.fromWorkload` — pipe-friendly composition
- `kix inspect` to see what you built
- `kix graph` to see the dependency DAG
- `kix build` to see the raw YAML output

**Implementation:** Mostly narration + existing commands. Could use VHS tape that "types out" the nix file, then builds it. Or a side-by-side: nix code on left, resulting YAML on right.

### 1.3 Cluster Definition — "How to Wire a Cluster"

**Audience:** Cluster operators, platform teams
**Story:** Define a cluster from scratch with namespaces, packages, config overrides
**What it shows:**
- `kix.buildCluster` with modules
- Namespace + instance declarations
- Package config overrides (`config.replicaCount = 3`)
- DI resolution (package depends on another, gets it injected)
- `kix list` → `kix inspect` → `kix graph` → `kix build`
- Flavors: `kix.flavors.kind` vs `kix.flavors.k3s` — cluster capabilities

**Implementation:** Use the `example` cluster definition (coredns + valkey + cert-manager + immich). Walk through the nix file, then show what it produces.

### 1.4 Diff Deep-Dive

**Audience:** Anyone doing change management / reviewing PRs
**Story:** Change a value in a cluster definition, see exactly what changes
**What it shows:**
- `kix diff kind` — live cluster comparison
- `kix diff kind --from ./previous-result` — build-to-build comparison
- Package-grouped output (nvd-style)
- Keyed-list-aware diffing (containers matched by name, not position)
- Rename detection
- Exit code 2 in CI for "changes detected"

**Implementation:** Ready today. Just needs a good scenario (e.g., change a config value, add a package, remove a package).

### 1.5 Dependency Graph Visualization

**Audience:** Anyone — universally impressive
**Story:** Show the full DAG of a real cluster, rendered as a graph
**What it shows:**
- `kix graph kind --format tree` — ASCII tree
- `kix graph kind --format dot | dot -Tsvg` — graphviz SVG
- `kix graph kind --format json` — for tooling
- Dependency edges from content-addressing (not declared — derived from interpolation)

**Implementation:** Ready today. Pipe dot output to graphviz for a visual. Could embed the SVG in a README or demo page.

### 1.6 Snapshot + Offline Diff

**Audience:** CI/CD pipelines, audit teams
**Story:** Save cluster state, compare against a build without cluster access
**What it shows:**
- `kix snapshot save kind ./snapshots/`
- `kix snapshot diff kind ./snapshots/`
- Offline change detection — no cluster needed for comparison
- CI integration: build in PR, diff against snapshot, fail if unexpected changes

**Implementation:** Ready today.

---

## Tier 2: Needs Moderate Work

These need implementation of planned features, but the design is clear.

### 2.1 Auto-Instantiation — "Just Make It Run"

**Audience:** Developers, PMs, anyone who hates dependency management
**Story:** Define an app that depends on postgres. Don't configure postgres. kix auto-creates it.
**What it shows:**
- Package declares `deps = { postgres = ...; }` in its function signature
- No postgres instance in the cluster definition
- `kix inspect` shows: postgres auto-instantiated from default package set
- `kix graph` shows the full transitive dep chain
- "I said I need postgres. kix figured out the rest."

**Implementation:** Auto-instantiation exists (`auto.nix`, `computeAutoInstances`). Needs a clean demo cluster that shows it clearly — an app with a hard dep on something not explicitly instantiated. The `test-auto` cluster might work but may need polish.

### 2.2 DI-Driven Defaults — "If It Exists, Use It"

**Audience:** Platform engineers
**Story:** Add an ingress controller to the cluster. All apps automatically get ingresses. Remove it — they gracefully degrade.
**What it shows:**
- DI resolution: explicit override → same-namespace → cluster-wide → default
- Conditional behavior: `if ingressNginx is injected, create an ingress`
- Adding/removing cluster capabilities changes app behavior at build time
- "The app doesn't know if it has ingress. It reacts to what's available."

**Implementation:** DI-driven defaults exist for immich, n8n, etc. Needs a demo scenario that's simple enough to follow. Could show the example cluster with and without cert-manager — watch TLS config appear/disappear.

### 2.3 Content-Addressing Explained

**Audience:** Technical deep-dive, architecture discussions
**Story:** Change one ConfigMap value. Watch the hash cascade through the DAG.
**What it shows:**
- Resource names are hashes of content
- Changing content → new hash → dependents get new hashes
- The cascade stops exactly where the influence stops
- Two builds of the same input produce identical hashes (determinism proof)
- `kix diff` between the two builds shows exact blast radius

**Implementation:** Works today in principle. Needs a demo cluster where the hash cascade is visible and dramatic — change a shared configmap, watch 10 resources get new hashes while 20 others stay unchanged.

### 2.4 Hardware Flavors — "One Definition, Many Targets"

**Audience:** Multi-cloud, hybrid teams
**Story:** Same cluster definition, different flavors (kind, k3s, rke2, eks)
**What it shows:**
- `kix.flavors.kind` vs `kix.flavors.k3s` vs `kix.flavors.hetzner`
- Capabilities change: loadBalancer available or not, storage classes differ
- Packages react: skip Ingress if no ingress controller, use different storage class
- Same intent → different manifests → correct for each environment

**Implementation:** Flavors exist in `lib/flavors/`. Needs build-to-build diffs showing how the same cluster produces different manifests per flavor.

### 2.5 Security Defaults — "Non-Root by Default"

**Audience:** Security teams, compliance officers
**Story:** All pods run as non-root by default. An app tries to override it. The override is visible and auditable.
**What it shows:**
- `mkDefault` sets security context on all pods
- Packages that need root must `mkForce` — this is greppable, auditable
- The priority hierarchy: mkDefault → normal → mkOverride → mkForce
- "Security isn't a bolt-on. It's the default. Overrides are intentional and visible."

**Implementation:** Needs implementation of security defaults via mkDefault (ROADMAP item). Not done yet.

### 2.6 Network Policy Derivation

**Audience:** Security teams, platform engineers
**Story:** No hand-written network policies. They're derived from the dependency graph.
**What it shows:**
- Package A depends on Package B → egress A→B and ingress B←A auto-generated
- Default deny posture set by platform team
- `kix graph` shows connection edges, `kix build` shows derived CiliumNetworkPolicies
- "If the dependency exists, the network path exists. Nothing more."

**Implementation:** `lib/netpol.nix` exists (430+ lines). Needs a demo cluster with Cilium on kind (cilium supports kind) to show live network policies.

---

## Tier 3: Needs Significant Work

These demonstrate vision-level features that aren't built yet.

### 3.1 Compiler Features — Build-Time Error Detection

**Audience:** Technical decision-makers, platform engineers
**Story:** Make mistakes. Watch kix catch them before anything touches a cluster.
**What it shows:**
- **Missing dependency:** Reference a postgres that doesn't exist → build-time error with suggestion
- **Version incompatibility:** Package requires K8s 1.29, cluster is 1.27 → build-time error
- **Extension mismatch:** Immich requires pgvecto.rs, postgres doesn't have it → build-time error with context
- **Cross-namespace violation:** Namespace-scoped resource used cross-namespace → build-time error
- "Every error you've ever debugged at 3am on a live cluster — caught at build time."

**What it references:** `29_compiler-design.md` sections 3-5 (what's compiled, what's not yet, compiler passes)

**Implementation:** Some checks exist (version bounds, extension validation, scope validation). Missing: CRD schema validation, API version deprecation checks, cross-reference validation. Each is an independent feature.

### 3.2 Compiler Features — CRD Schema Validation

**Audience:** Anyone writing custom resources
**Story:** Typo in a cert-manager Certificate CR field. kix catches it at build time.
**What it shows:**
- `mkCRD` carries the OpenAPI schema
- `mkCR` validates against it
- Wrong field name → "did you mean X?"
- Wrong type → "expected string, got int"
- Missing required field → "field X is required by CRD Y"

**What it references:** `29_compiler-design.md` section 4.7

**Implementation:** `mkCRD` has schemas, `mkCR` doesn't validate yet. Needs a validation pass in `mkCR`.

### 3.3 Compiler Features — Connection Graph + Port Fan-Out

**Audience:** Deep technical audience
**Story:** Declare "this app talks to postgres on 5432." Watch the compiler derive env vars, network policies, and validate the port exists.
**What it shows:**
- Connections as typed edges (not just DI injection)
- Env vars derived from connection declaration
- NetworkPolicies derived from connection graph
- Port consistency validated across the chain
- "You said what you meant. The compiler figured out the YAML."

**What it references:** `29_compiler-design.md` sections 4.1-4.3

**Implementation:** Design exists, no implementation yet.

### 3.4 Compiler Features — Whole-Cluster Analysis

**Audience:** Platform architects
**Story:** Two Services accidentally select the same pods. kix catches it.
**What it shows:**
- Selector uniqueness across the cluster
- Port conflicts on shared LoadBalancers
- Resource quota fit analysis
- Network reachability verification

**What it references:** `29_compiler-design.md` section 5 (Pass 5: Whole-Cluster Analysis)

**Implementation:** None yet. Requires post-evaluation analysis passes.

### 3.5 PR Preview Environments

**Audience:** Dev teams, CI/CD teams
**Story:** Open a PR. Get an isolated deployment that reuses unchanged services.
**What it shows:**
- Content-addressing means unchanged services are literally the same resource (same hash)
- Only changed services get new instances
- PR deployment is isolated for what changed, shared for what didn't
- "Your PR is running. It shares 90% of the cluster. The 10% you changed is yours."

**What it references:** MAJOR_FEATURES.md item 9, ROADMAP "PR as its own isolated deployment"

**Implementation:** Requires multi-activation support and shared resource semantics. Deep design work.

### 3.6 Canary / Wave Rollouts

**Audience:** SRE teams, anyone doing progressive delivery
**Story:** Deploy a new version alongside the old. Route traffic gradually.
**What it shows:**
- Different hash = different resource = can run side-by-side
- Unchanged dependencies are shared (same hash)
- Traffic shifting from old hash to new hash
- Instant rollback: point back to old hash

**What it references:** MAJOR_FEATURES.md items 7-8

**Implementation:** The DAG model supports this in theory. Needs traffic management integration (service mesh, gateway API).

### 3.7 Vertical Integration — Source to Running Container

**Audience:** Engineering leadership, anyone evaluating build systems
**Story:** From Rust source code to running pod. One command. Fully reproducible.
**What it shows:**
- Nix builds the binary
- Nix builds the container image
- kix deploys the container
- Change a line of code → only the affected resources redeploy
- "Same hash means same binary means same container means same deployment. Bit-for-bit."

**Implementation:** Requires nix-snapshotter or container image building integration. Significant work.

### 3.8 Air-Gapped Deployment

**Audience:** Defense, regulated industries, enterprise
**Story:** Build a cluster on an internet-connected machine. Deploy to a machine with no internet.
**What it shows:**
- `nix copy --to` transfers the full closure
- All dependencies are locked and content-addressed
- No downloads during deploy — everything is in the store
- "The air gap is a feature, not a limitation."

**What it references:** `47_air_gapped_deploys.md`

**Implementation:** Design exists. Needs container image mirroring solution.

---

## Tier 4: Aspirational / Long-Term

### 4.1 Topology-Aware Monitoring

Auto-generated Grafana dashboards, PrometheusRules, and alerting from the dependency graph. "The monitoring configures itself from the architecture."

### 4.2 Cross-Cluster Comparison

Two clusters that should be identical (staging vs prod). Compare activation hashes. Find exactly where they diverge. "Staging and prod differ in exactly 3 resources."

### 4.3 "What If" Analysis

"What happens if I upgrade postgres from 15 to 16?" Build both. Compare DAGs. See exact impact. Before touching anything.

### 4.4 Functional CRDs

Deploy against kix, not K8s directly. CRD operators replaced by pure evaluation where possible. "You don't install an operator. You describe what you need. kix computes the manifests."

### 4.5 Local Dev Loop

Tilt-inspired watch + rebuild + deploy cycle. Change code, kix rebuilds and redeploys in seconds. Inner-loop iteration without leaving the terminal.

### 4.6 Supply Chain Audit

Walk the Merkle DAG from activation root to leaf. Every hash verifiable. Every dependency traceable. "Has this cluster been tampered with?" → compare hashes. The answer is cryptographic, not hopeful.

---

## Demo Packaging Ideas

### Format options
- **VHS GIF** — current approach, good for README/website, self-contained
- **Asciinema** — terminal recording with copy-paste support, better for tutorials
- **Live demo** — most compelling for talks/meetings, riskiest
- **Side-by-side** — nix code on left, resulting resources on right (for package authoring demos)
- **Split terminal** — k9s or operator logs alongside CLI (for lifecycle demos)

### Demo index page
A simple page (or README section) linking to all available demos with one-line descriptions:
- "Full lifecycle (3 min)" → cli-demo.gif
- "Package authoring (5 min)" → package-demo.gif
- etc.

### Progressive complexity
Demos should be watchable in order, each building on the previous:
1. "What does kix produce?" (build + inspect)
2. "How do I deploy?" (deploy + health)
3. "How do I write a package?" (package authoring)
4. "How do I wire a cluster?" (cluster definition)
5. "What happens when things break?" (lifecycle demo)
6. "What does the compiler catch?" (build-time errors)
7. "Where is this going?" (vision demos)

---

## Planned Demo: "The Compiler Catches Everything" (VHS Tape)

**Audience:** Platform engineers, technical decision-makers, anyone evaluating kix
**Format:** Single VHS tape, ~3-5 min, continuous narrative
**Protagonist:** Immich (real app, real postgres+pgvecto.rs dependency)
**One-line:** Missing → wrong → automatic → governed → composable → traceable — all at build time.

### Scene 1 — Missing DI

Define a cluster with immich but no postgres instance.

```
kix build demo-cluster
```

→ **Build-time error:** immich requires `postgres` but no instance is available.

**Beat:** "You forgot something. The compiler caught it before anything touched a cluster."

### Scene 2 — Wrong Usage

Add a postgres instance, but without the pgvecto.rs extension that immich needs.

```
kix build demo-cluster
```

→ **Build-time error:** immich requires pgvecto.rs extension but postgres doesn't provide it.

**Beat:** "You provided the wrong thing. The compiler knows what immich actually needs."

### Scene 3 — Auto-Configuration

Don't remove the explicit postgres — just leave it unlocked. Immich's DI injection auto-configures postgres with the right extensions.

```
kix build demo-cluster  # succeeds
kix inspect demo-cluster postgres
```

→ Postgres now has pgvecto.rs enabled — configured by immich via dependency injection.

```
kix graph demo-cluster --format tree
```

→ Shows the dependency edge: immich → postgres.

**Beat:** "Immich said what it needs. The compiler configured postgres to match. No manual wiring."

**Variant (auto-instantiation):** Also show: remove the explicit postgres entirely, enable auto-instantiation. Same result — postgres appears in the graph, correctly configured.

### Scene 4 — Locked Fields Enforce Team Boundaries

Platform team locks the postgres `extensions` field with `mkLocked`.

```nix
# cluster definition
postgres.config.extensions = kix.mkLocked [ "pg_stat_statements" ];
```

```
kix build demo-cluster
```

→ **Build-time error:** `dep config injection blocked by locked fields: 'extensions' (injected by immich)`

**Beat:** "The platform team said: these extensions, nothing else. Immich tried to add pgvecto.rs via DI. The compiler enforced the boundary. This is team governance at build time."

### Scene 5 — DI-Driven Defaults Compose

Unlock postgres again. Add cert-manager to the cluster.

```
kix build demo-cluster  # succeeds
kix diff demo-cluster
```

→ Diff shows: immich's ingress now has TLS annotations + a Certificate CR. Postgres unchanged.

**Beat:** "We added cert-manager. Immich noticed and configured TLS automatically. No one edited immich's config."

### Scene 6 — Content-Addressing Reveals Blast Radius

Change a postgres config value (e.g., `max_connections`).

```
kix diff demo-cluster
```

→ Postgres resources get new hashes. Immich gets a new hash (depends on postgres). Cert-manager is untouched.

**Beat:** "One config change. The diff shows exactly what's affected — and what isn't. The blast radius is computed, not guessed."

### Summary Slide / Closing

> Six scenarios. Zero cluster access. Every mistake caught, every dependency resolved, every boundary enforced — all before a single manifest reaches the API server.
>
> That's what a compiler for Kubernetes looks like.
