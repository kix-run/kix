# 129: The multi-* stress test — fleet as a build system, activations as linked objects

**Status:** RFC / Brainstorm
**Related:** `129a_grounding_field_and_prior_art.md` (evidence pass — amendments A1–A6 applied here), `45_multi_team_and_operator_models.md` (team spectrum), `55_shared_resource_ownership.md` (recast in §6), `91_cicd_organizational_patterns.md` (CI patterns), `127_compiler_target_model.md` (targets/roles — the foundation this builds on), `127_ludo_multi_site_target_architecture.md` (first stretch-cluster data point), `interesting_thoughts/69_hardware_driven_scheduling.md` (fleet breadth exploration), `65_passthrough_instances.md` + `97_service_contract_primitives.md` (get their driver in §5), `117_self_service_platform_interface.md`

Pressure test: push the current compiler (post ring-model rewrite, post role
registry) against the five axes that judge scalability — multi-cluster,
multi-cloud, multi-region/AZ, multi-team, multi-activation. The claim of this
doc: **each axis is a standard toolchain question, kix already holds the right
atom, and the two genuinely missing primitives are the same primitive twice.**

## 1. Five axes, two questions

Every "multi-" reduces to one of two toolchain questions:

| Axis | Toolchain question | Concept |
|---|---|---|
| multi-cloud | "what target am I compiling for?" | cross-compilation (doc 127 targets) |
| multi-region/AZ (in one cluster) | "what does the target's sub-architecture look like?" | substrate topology axioms (127 §4) |
| multi-cluster | "how do separately compiled units reference each other?" | separate compilation + interface artifacts |
| multi-team | "who authors which part of one compilation, or who ships their own unit?" | module layering vs. separate units |
| multi-activation | "how do multiple loaded objects share one address space?" | dynamic linking + symbol ownership |

Two hard-won lessons from the platforms that tried this before us, taken as
constraints:

1. **The cluster stays the compilation unit and the failure domain.** Borg
   never had a global cell; kubefed died twice; GKE Fleet / Anthos converged
   on *config distribution + per-cluster reconciliation*, not federated
   control planes. We never evaluate two clusters into one graph.
2. **The fleet layer is a build system, not a compiler.** Cargo workspaces
   don't extend rustc; they orchestrate invocations and hold the lockfile.
   Everything fleet-level must be a stateless function over per-cluster
   *artifacts* (built closures, exports files, activation history) — never
   shared evaluation state, never a runtime meta-scheduler.

The verdict per axis, argued below:

| Axis | Current state | Gap |
|---|---|---|
| multi-cloud | architecturally solved (targets, roles, vendor-field rule) | preset corpus + `kix target probe` (127 §5, already planned) |
| multi-region/AZ | designed (substrate vocabulary 127 §4; stretch topology 127-ludo) | zone→spread/PDB derivation not built (already on 127's list) |
| multi-cluster | ad-hoc (attrset of clusters in `mkFlake` works today) | **interface-export artifact** + fleet verbs over built outputs |
| multi-team | compile-time path solid (module layering + scorecard); link-time path blocked | blocked on multi-activation |
| multi-activation | annotations exist (`kix.dev/activations`, import markers) but no model | **export/import contracts + single-owner rule + deploy-time linker** |

Rows 3 and 5 share their gap: a **contract artifact** for references that
cross a compilation boundary. That is the one new primitive this doc proposes.

## 2. Multi-cloud: already the right shape — finish the corpus

Doc 127 solved this axis conceptually and the role registry shipped its core:
packages branch on facts (roles, substrate axioms), never on
`cluster.provider`; binding modes make environment-owned roles refusable at
eval. Pushing to real multi-cloud is *content*, not architecture:

- Curated target presets for EKS / GKE / AKS / Hetzner (today 9 of 13 flavors
  are guesses — `kix target probe` is the fix and the adoption feature).
- New roles as clouds demand them, through the existing registry: the first
  real one is **cloud workload identity** (IRSA vs. GKE Workload Identity vs.
  Azure WI are three providers of one `cloud-identity` role with a shallow
  out-contract: "annotate this SA, get these tokens"). Secrets-manager
  backends are the second.

The multi-cloud test case is one service module compiled against three
targets:

```nix
# fleet/clusters/api-eu.nix     — GKE
kix.buildCluster { name = "api-eu";  modules = [ kix.targets.gke  ./api-base.nix ]; }
# fleet/clusters/api-us.nix     — EKS
kix.buildCluster { name = "api-us";  modules = [ kix.targets.eks  ./api-base.nix ]; }
# fleet/clusters/api-edge.nix   — Hetzner k3s
kix.buildCluster { name = "api-edge"; modules = [ kix.targets.k3s ./api-base.nix ]; }
```

`api-base.nix` contains zero provider conditionals. Where the three builds
differ (storage provider, LB role binding, identity provider), the diff is a
role resolution visible in the artifact — `kix diff api-eu api-us` at the
package level answers "what does moving clouds actually change." That command
already exists (build-to-build mode); it becomes the cloud-migration
estimator for free.

## 3. Multi-region/AZ: two different things — name them apart

**Inside a cluster** (multi-AZ, stretch): substrate topology axioms
(127 §4 zones/racks/fabrics) plus the planned derivation
(topologySpreadConstraints, PDB posture, zone-aware storage). 127-ludo is the
first real data point (placement tiers, per-site storage). Nothing new needed
here; this doc just ratifies that *region within a cluster is a substrate
fact*.

**Across clusters** (multi-region deployments): in production practice a
region is a cluster boundary — regional clusters, not stretched ones, are the
default above homelab scale (blast radius, API-server latency, upgrade
independence). So cross-region is the multi-cluster axis wearing a
geography label. The region becomes *fleet metadata on the cluster*, used for
placement and policy:

```nix
cluster.meta = {              # fleet-facing identity, not substrate
  environment = "production";
  region = "eu-central";
  jurisdiction = "EU";        # data-residency policy input
  tier = "tier-1";
};
```

Data-residency enforcement is then a fleet check, not a package assertion:
"no package with `meta.dataClass = "pii"` compiles into a cluster whose
`jurisdiction` ∉ allowed set" — evaluated per cluster (it's still a
single-cluster eval reading its own options), *reported* fleet-wide (§7).

## 4. Multi-cluster: separate compilation, one flake, data-driven stamping

The atom holds: `mkFlake` already takes `clusters = { … }` and each is an
independent evaluation. The fleet story is three additive layers.

**Layer 1 — templates over data (exists in spirit, promote to pattern).**
200 edge sites are a `mapAttrs` over an inventory file calling one template
(doc 69 Part 2 has the full worked example). No new mechanism; document it
and give `mkFlake` a `clusterTemplates`/data hook so the flake stays
readable:

```nix
outputs = inputs: inputs.kix.lib.mkFleet {
  inherit inputs;
  clusters = {
    prod-eu = ./clusters/prod-eu.nix;
    prod-us = ./clusters/prod-us.nix;
  } // kix.lib.stampClusters {
    template = ./templates/edge-store.nix;         # storeId, region, nodeSpec → cluster
    data = builtins.fromJSON (builtins.readFile ./stores.json);
  };
};
```

**Layer 2 — fleet analysis runs in Rust over built artifacts, not in Nix.**
Fleet-wide checks (version skew between staging and prod, policy coverage,
image-arch coverage, residency report) need all clusters' *outputs*, not
their evaluations. Doing this as a Nix-level fold over 200 evals is the wrong
engine (doc 120's split: Nix computes, Rust analyzes). The activation output
already carries everything needed (`kix-packages.json`, scorecard JSON,
images). Fleet verbs are set operations over those JSON artifacts:

```
$ kix fleet build                 # parallel nix build over all cluster outputs
$ kix fleet check
  ✓ policy: podHardening=restricted on all 4 prod clusters
  ✗ skew:   prod-us runs immich 1.119, prod-eu 1.121 (staging: 1.121)
  ✗ residency: user-data-service (pii) present in staging-us [jurisdiction US]
  ✓ arch:   all edge images provide arm64
$ kix fleet diff --since HEAD~1   # per-cluster package-level diff, one table
```

Cheap because content addressing makes "did anything change in cluster N"
a hash comparison — a PR touching one package re-evaluates only clusters that
transitively include it, and the fleet diff for the other 196 clusters is a
cache hit with an identical activation hash.

Three additions from the evidence pass (129a A5/A6): fleet checks also cover
**drift aggregation** (per-cluster `kix drift` rolled up — config drift causes
compliance failures for 34% of enterprises; this is the wedge) and **cost
estimation** (request totals × target instance catalog at review time — cost
is the field's #1 pain). And the fleet layer gets exactly one global
semantic computation — **pin coherence** (which package/input versions each
cluster builds against; skew report first, resolver later) — named and
designed in rather than left to grow outside the tool, because no workspace
layer in build-system history stayed computation-free. Cluster identity maps
onto the emerging ClusterProfile / Cluster Inventory API; `kix target probe`
consumes and emits it.

**Layer 3 — cross-cluster references via interface exports (the new
primitive).** When cluster B's workloads talk to a service in cluster A
(regional auth, central SSO, replicated DB primary), today that's a raw URL
string — invisible to the graph. The wrong fix is live cross-evaluation
(couples failure domains and release cadences; the kubefed mistake). The
right fix is the C model: separate compilation against a **header**.

Cluster A declares exports; its build emits a content-addressed contract
file next to the activation:

```nix
# clusters/prod-eu.nix
exports.auth = {
  from = "identity.keycloak";                  # instance whose out-contract is exported
  contract = [ "url" "issuer" "caBundle" ];    # the slice of `out` that is public ABI
};
```

```jsonc
// result/kix-exports.json  (content-addressed, checked into locks/ or fetched from the registry)
{ "cluster": "prod-eu", "activation": "sha256-…",
  "exports": { "auth": { "url": "https://auth.eu.example.com", "issuer": "…", "caBundle": "…" } } }
```

Cluster B imports it as a **passthrough instance** (docs 65/97 finally get
their concrete driver): zero resources, real `out`, full DI participation:

```nix
# clusters/prod-us.nix
imports.prod-eu = kix.importCluster ./locks/prod-eu.exports.json;

instances.app.api = {
  package = packages.api;
  deps.auth = "prod-eu/auth";     # resolves like any DI dep; out = the pinned contract
};
```

Properties that fall out:

- **Blast radius across clusters is a lockfile diff.** A changes its auth
  URL → new exports hash → `kix fleet update-locks` bumps B's pinned file →
  B's diff shows exactly which resources re-wire. Same Merkle story as
  in-cluster (29 §8), extended across the boundary by an explicit artifact.
- **Deploy-time verification exists already.** The import lowers to the
  existing PackageInstance import marker; the only extension is that the
  target lives behind an endpoint instead of in the local cluster (readiness
  = contract health probe instead of API-server poll).
- **Staleness is visible, not silent.** The lock carries the source
  activation hash; `kix fleet status` flags "B pinned prod-eu@gen41, live is
  gen44 — exports unchanged" (fine) vs. "exports differ" (action needed).
  Staleness *policy* — bump cadence, gates, producer-side notification when
  a referenced contract version is about to sunset — is part of the design,
  not an afterthought: every pin-based system that shipped without it
  (flakes, Terragrunt) got silent divergence as its #1 complaint (129a §2).
- **Contracts are compiler-emitted and versioned glibc-style** (129a A2):
  the provider carries all live contract versions, the consumer's lock
  records the version it linked against, and a fleet check forbids dropping
  a version any lock still references. Service-shaped contracts can *lower
  to* MCS `ServiceExport`/`ServiceImport` where an MCS transport exists —
  kix models the contract; MCS, DNS+GSLB, or a plain pinned URL are its
  rendering targets.
- Transport (mesh federation, VPNs, DNS) stays out of scope: kix models the
  contract, the network layer provides the path. Same division of labor as
  in-cluster netpol vs. CNI.

## 5. Multi-team: layering when trust is high, linking when it isn't

Doc 45's spectrum stands; this doc assigns each end its compiler mechanism
and names the enforcement honestly.

**Compile-time composition (monorepo/federated → one activation).** Teams own
module files; the operator owns policy modules; the compiler is the
integration point (91 §5). What's real today: budgets and postures as module
options, scorecard rules as constraints, SARIF into review. What is *not*
real: `mkForce` is not a permission system. Authority is enforced at the git
layer (CODEOWNERS on `policies.nix`) and made *visible* at the compile layer
— a scorecard rule that fails when an effective policy value differs from the
policy module's declaration catches the bypass even if the merge slipped
through. Sell it as "violations are visible", not "impossible"; a stronger
module-layer permission model has no consumer yet.

```
clusters/prod-eu/
  default.nix        # operator: target + policies + budgets + exports
  policies.nix       # operator-owned (CODEOWNERS-gated)
  teams/
    payments.nix     # instances + config, budgeted namespace
    search.nix
```

**Link-time composition (independent cadence → multiple activations).** The
enterprise end of the spectrum. Blocked today on doc 55; unblocked by §6.
Crucially, the *sliced* middle ground (below) means teams don't have to
choose repo independence to get deploy independence.

**The registry model** (91 §3) is unchanged: teams publish versioned
packages, cluster owners pin and compose. Federated flakes are the publish
mechanism until a real registry earns its keep.

## 6. Multi-activation: dynamic linking, single ownership, no refcounts

Recasting doc 55 with the vocabulary we shipped since: **an activation is an
object file loaded into the cluster's address space; roles and DI aliases are
its symbols.** Today the compiler links statically (one activation resolves
everything internally). Multi-activation is dynamic linking, and the linker
rules follow from the refusal law we already enforce at eval:

1. **Every resource has exactly one owner activation.** Co-ownership
   (reference counting on shared resources) is rejected: it destroys
   attribution, makes GC racy, and reintroduces "who broke the CRD".
   `kix.dev/activations` stays as *reference* bookkeeping, never ownership.
2. **Shared infrastructure is an activation, not an annotation.** CRDs,
   cert-manager, the operator itself live in an `infra` activation that
   other activations import. This is doc 55's "infrastructure activation"
   option, chosen.
3. **Cross-activation references use the same contract artifact as §4.**
   Importing `infra/cert-manager` from the same cluster and `prod-eu/auth`
   from another cluster is one construct with a different address. Symmetry
   is the design argument: one primitive, two distances.
4. **Duplicate strong symbol across activations is a linker error.** Two
   activations both claiming role `cni`, or both owning
   `Namespace/monitoring`, is refused at deploy — the eval-time
   duplicate-symbol law (127 binding modes) extended to deploy time, where
   separate evaluations make eval-time detection impossible. The operator
   maintains the cluster symbol table from PackageInstance export markers;
   `kix deploy` consults it before applying.

**Sliced compilation — the monorepo's best of both.** One cluster definition
can *compile to multiple activations*: whole-cluster evaluation (full DI,
netpol, cross-team checks — everything stays eval-time), then the graph is
cut at declared boundaries and each slice becomes its own activation whose
cross-slice edges are lowered to import markers automatically:

```nix
kix.buildCluster {
  name = "prod-eu";
  modules = [ … ];
  activations = {                       # absent → one activation, status quo
    infra = { includes = [ "kube-system.*" "cert-manager.*" "monitoring.*" ]; };
    payments = { includes = [ "payments.*" ]; };
    search   = { includes = [ "search.*" ]; };
  };
}
```

The compiler checks the cut is legal (no strong symbol claimed by two
slices; every cross-slice edge is contract-shaped — a service endpoint or an
established CRD, not a mid-wave resource dependency) and refuses otherwise.
Teams get independent `kix deploy prod-eu --activation payments` cadence with
zero loss of compile-time integration. **Slices are generation-atomic**
(129a A1, the ThinLTO rider): all deployed slices must come from one
whole-cluster evaluation, *except* that a slice may lag behind if every
contract hash on its cut edges is unchanged between the generations —
content addressing turns "is this mix safe" into a hash-equality check. Independent-repo teams (45 §2c) get
the same linker semantics without the shared eval — they just lose the
eval-time cross-team checks, which is the price of that org choice, stated
plainly.

## 7. Workflows and CLI

The fleet layer holds no state beyond git and per-cluster activation history.

```
# authoring
kix target probe --context prod-eu > targets/prod-eu.nix      # environment lockfile (127)
kix fleet update-locks                                         # refresh pinned exports files

# CI on PR (per affected cluster — affected = activation hash changed)
kix fleet build --changed-only
kix fleet check                                                # skew / policy / residency / arch
kix diff prod-eu --output markdown                             # PR comment, exists today

# rollout (an ordered fold over the existing single-cluster verb)
kix fleet deploy --order staging-eu,prod-eu,prod-us --gate healthy --bake 30m
kix fleet status                                               # activations, lock staleness, drift

# environment promotion = pin propagation + hash proof, not a new deploy path
kix promote staging-eu prod-eu                                 # copies pins, then:
  → cross-cluster diff: 3 resources differ (replicas, storage class) — expected target delta
```

Promotion deserves the note: because environments are compilation parameters
(91 §6), "staging equals prod" is provable — after promotion, the two
activation DAGs must differ only where their targets differ, and `kix
promote` prints exactly that residue. No other toolchain in this space can
state the staging/prod delta as a closed set.

Deploy topology stays doc 45's: thin per-cluster operators, brain in CI (or
kix-cloud later). `kix fleet deploy` is a client-side orchestration loop with
health gates — deliberately boring; the interesting guarantees live in the
artifacts.

## 8. What we refuse to build

- **Federated evaluation / fleet-level DI graph.** Couples failure domains;
  contracts-by-artifact carry the same information with independent cadence.
- **A meta-scheduler — for long-lived services** (scoped per 129a A4).
  Service placement is a decision expressed in git (which cluster files
  instantiate the package), not solved at runtime. Karmada-style propagation
  policies reintroduce exactly the invisible wiring kix exists to kill.
  Exception, explicitly in scope for interop: run-to-completion batch/AI
  dispatch (MultiKueue-style capacity chasing) is legitimate dynamic
  placement — kix compiles the *placement domain* (candidate cluster set,
  queues, quotas) and the dispatcher picks within it at runtime. DR failover
  likewise: kix compiles both stances; DNS or operators flip.
- **Cross-activation transactions.** The activation remains atomic; ordering
  between activations is expressed by import readiness, not a 2PC.
- **Runtime cross-cluster networking.** Mesh/VPN/DNS federation is
  transport; kix models the endpoint contract only.

## 9. Judgment on the current foundations

Pushing the axes validates the rewrite more than it bends it:

- **Right already:** cluster-as-compilation-unit; content addressing (fleet
  ops become hash set operations); targets/roles (multi-cloud is content
  work); Nix-computes/Rust-analyzes split (fleet checks land in the CLI, not
  in eval); import markers + readiness (the deploy-time half of linking
  exists).
- **The one new primitive:** the export/import contract artifact — needed
  twice (cross-cluster §4, cross-activation §6), same shape both times, and
  it finally gives docs 65/97 their driver.
- **The one new compiler feature:** activation slicing (§6) — a graph cut +
  legality check inside `buildCluster`, additive to the ring model (the cut
  runs after the fixpoints, over the sealed graph, so it does not touch
  Ring 0 semantics).
- **Sequencing:** nothing here blocks current work; conversely doc 126's
  rewrite discipline (byte-identical manifests) is what makes the slice cut
  and the exports file safe to add later. Ordering when the demand arrives:
  exports artifact → sliced compilation → fleet verbs → probe/preset corpus
  (already planned).

## 10. Open questions

1. **Contract schema.** ~~Is `kix-exports.json` a bare out-slice, or does it
   carry types/versioning?~~ Answered by 129a A2: compiler-emitted, versioned
   glibc-style (provider carries all live versions, consumer lock records the
   linked one, fleet check guards sunsets). Remaining: whether link-time
   `out` typing (doc 120's biggest gap) lands here — the export is exactly
   an ABI.
2. **Lock custody.** Pinned exports in-repo (`locks/`, flake-lock-style) vs.
   fetched from an artifact registry at build time? In-repo is purer and
   diff-visible; registry scales to 200 clusters. Probably both, in that
   order.
3. **Slice legality.** What exactly may cross a slice boundary? Endpoint
   contracts and established CRDs clearly yes; secrets refs probably;
   owner-references and webhook wiring probably not. Needs the same
   edge-class analysis netpol uses.
4. **Symbol table residence.** PackageInstance export markers vs. a
   dedicated `ClusterSymbol` CR — does the operator need the table to
   survive activation GC?
5. **Fleet check authorship.** Are fleet checks scorecard rules evaluated
   over a synthetic "fleet document", or a separate rule family in the CLI?
   (Leaning CLI-native over built artifacts, per §4 Layer 2.)
6. **Does `kix promote` earn its verb**, or is it `kix diff a b` plus a pin
   copy script until a customer asks?
