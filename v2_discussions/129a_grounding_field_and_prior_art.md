# 129a: Grounding 129 — build-system prior art, field evidence, and the top-down inversion

**Status:** Analysis / Brainstorm
**Related:** `129_scaling_axes_fleet_and_linking.md` (the theses under test), `127_compiler_target_model.md`, `45_multi_team_and_operator_models.md`, `91_cicd_organizational_patterns.md`, `117_self_service_platform_interface.md`

Three research sweeps (2026-07, web-verified) run against doc 129's claims:
(a) how compilers/build systems scaled past one compilation unit, (b) what
enterprises actually do and want at multi-cluster scale, (c) what a decade of
multi-cluster tooling learned. Verdicts first, then the two analysis sections
129 didn't have: what top-down intent compilation *changes*, and what
maintenance / "compiling clouds together" concretely look like. §8 lists the
amendments applied back to 129.

## 1. Verdict summary

| 129 thesis | Verdict | Decisive evidence |
|---|---|---|
| Cluster = compilation unit; never federate evaluation | **Confirmed** | Fed v1 dead; kubefed archived 2023 with *no endorsed successor*; SIG-MC retreated to primitives (inventory, MCS, Work API); Argo CD itself is building a pull-based per-cluster agent (argocd-agent); newest entrants (k0rdent 2025) compose Flux+Sveltos instead of inventing propagation |
| Region = cluster boundary | **Confirmed, sharpened** | etcd/Raft over WAN is the universally cited blocker; AKS/GKE reference architectures are cluster-per-region. Sharpening: **latency is the real boundary** (metro-DC stretch clusters exist), and cells (DoorDash, Slack) cut *finer* than region — "region ⊆ cluster-boundary reasons" |
| Fleet = build system, stateless over artifacts | **Confirmed with one big caveat** | Cargo/Turborepo/Terragrunt all succeed as DAG runners over unit artifacts. Caveat: **no surveyed workspace layer stayed a dumb orchestrator** (§2) |
| Pinned contract artifacts over live resolution | **Strongly confirmed** | Terragrunt's live remote-state reads are the documented anti-pattern (stale, undeclared coupling, partial failures); Cargo publish boundary, Go MVS pins, glibc symbol versions, Swift `.swiftinterface` all converged on "consumer records an immutable versioned interface." Field side: mainstream cross-cluster connectivity is DNS/GSLB + explicit endpoints, not federated mesh (§3) |
| Duplicate-ownership linker refusal | **White space confirmed** | Only runtime analogues exist (SSA conflicts, Argo tracking-id warnings, Fleet bundle conflicts). ELF history is the warning: unenforced ODR = decades of silent corruption; enforce hard, at the compiler/linker layer |
| No meta-scheduler; placement in git | **Confirmed for services, WRONG for batch/AI** | Long-lived service placement is a git decision everywhere that matters (ApplicationSets, per-cluster GitOps, Chick-fil-A repo-per-restaurant). But MultiKueue (beta, on by default) and SkyPilot-style GPU capacity chasing are legitimately *dynamic* — price/capacity move hourly and git can't express that. Scope the refusal (§8-A4) |
| Provable env parity / compile-time validation | **White space confirmed** | Nobody does content-addressed per-cluster closures; ecosystem drift toward "hydrated manifests in git" is directional validation; Crossplane's loudest criticism is **no plan/preview phase** — the field explicitly asks for what kix leads with |

## 2. Build-system lessons (the ones that change 129)

1. **Every workspace layer eventually grew one global semantic computation.**
   Cargo: feature unification is a whole-workspace fixpoint (which union you
   get depends on which subset you build — RFC 3692 added resolver policy
   knobs, and cargo-hakari exists to pin the fixpoint *outside* the tool).
   Bazel: toolchain resolution + MVS. Go: MVS is a global graph algorithm.
   Nix: `follows` is manual version unification, and flake-parts is a full
   module evaluator bolted onto a composition layer that didn't compose.
   Lesson: don't pretend the kix fleet layer will stay computation-free —
   **name its one global computation now and design it MVS-style (simple,
   deterministic, explainable)**. The kix candidate: *pin coherence* — which
   package/input versions each cluster builds against, checked (read-only:
   skew report) and resolved (write: fleet-wide pin bump). If we don't build
   it, a hakari-equivalent will grow outside the tool.
2. **ThinLTO is the proof for activation slicing — with an atomicity rider.**
   Whole-program analysis over cheap per-unit *summaries*, then fully
   parallel per-module backends. But ThinLTO outputs are only coherent as a
   set: you cannot mix backend outputs from index N and N+1. Kix equivalent:
   **slices from one whole-cluster evaluation form one generation; deploying
   mixed generations is refused** unless the cross-slice contracts are
   provably unchanged (hash equality of the import contracts is exactly that
   proof — content addressing gives us the safe-mix check ELF never had).
3. **Interface artifacts must be compiler-emitted, never hand-authored.**
   C headers (manual) rotted; Swift moved to compiler-emitted
   `.swiftinterface`; Pants' whole pitch is inferring unit metadata from
   source. 129's `exports.contract = [ "url" "issuer" … ]` declaration is
   fine (it selects what is public), but the artifact itself must be built
   output, and *consumption* should be derivable (the DI graph already knows
   which `out` fields B reads — that is the inferred import list).
4. **ABI evolution: copy glibc symbol versioning.** Provider carries all
   supported contract versions; consumer records the version it linked
   against (`memcpy@GLIBC_2.2.5` forever). For kix: the exports file carries
   versioned entries; the importing cluster's lock records
   `auth@v2 (sha256-…)`; the provider may not drop v2 while any lock in the
   fleet references it — a *fleet check* enforces this (compile-time
   ODR-across-clusters). This answers 129 open question 1.
5. **Staleness policy is the product surface, not the pin.** Flakes,
   lockfiles, Terragrunt: every pin-based system pushed updates out-of-band
   to bots and humans, and silent divergence became the #1 complaint.
   `kix fleet update-locks` must ship with policy semantics (who bumps, what
   gates, how consumers are notified when a producer publishes v3), not just
   a verb. This is where 129's model would fail in practice if left as sugar.
6. **Per-unit metadata maintenance kills adoption** (Bazel BUILD files;
   Kubernetes removed Bazel over it). Everything fleet-level that can be
   derived from the graph must be derived, not declared twice.

## 3. Field evidence (what enterprises actually do)

**Scale is the default posture.** Spectro Cloud 2025: enterprises average
>20 clusters across 5+ environments; top pains are **cost (42%, #1)**,
consistent management (49%), and **compliance failures caused by config
drift (34%)**. Fleet realities: Mercedes-Benz ~900 clusters
(cluster-per-team, moving to Cluster API), Chick-fil-A ~2,800 edge clusters
(**one git repo per restaurant** + on-site pull agent — placement-in-git at
the largest documented scale), Zalando 100+ (cluster pairs per domain),
DoorDash cells (each service in exactly one cluster per cell, **cross-cell
traffic prohibited** — a compile-time-checkable rule if placement is in git).

**Connectivity practice supports contracts-over-mesh-magic.** Mesh
federation carries documented quadratic config cost (OpenShift: n·(n-1)
gateway configs), hard caps (Cilium ClusterMesh: 255 cluster IDs, immutable
MaxConnectedClusters), and "too granular for human consumption" complaints
(Istio, per Salesforce). The pragmatic mainstream: DNS + global LB + health
checks + explicit endpoints. The MCS API (ServiceExport/ServiceImport) is
itself contract-shaped and is where upstream is heading — so the kix
contract artifact should be able to **lower to** a ServiceExport/Import pair
when an MCS transport (GKE MCS, Submariner, Cilium MCS-API, Linkerd
federated services) is present: kix models the contract; MCS is one
rendering target of it, DNS+GSLB another, a plain pinned URL the third.

**Drivers, ranked by evidence:** blast-radius isolation (cells), upgrade
independence (blue/green *cluster replacement* is an established pattern —
stand up new cluster, validate, shift, decommission), data
sovereignty (DORA makes single-hyperscaler dependence a formal concentration
risk; EU sovereign-cloud procurement with SEAL levels, 2026), HA/DR
(active-passive remains the recommended default when state is involved;
failover is DNS, not mesh), and — the new one — **AI/GPU capacity chasing**
(SkyPilot, MultiKueue), the one legitimately dynamic-placement domain.

**The intent vacuum.** No workload-intent model won: KubeVela/OAM is real
but China-concentrated; Score stayed minimal; the de-facto intent layer is
Helm umbrella charts + ArgoCD app-of-apps + Terraform + tickets. Meanwhile
platform engineering adoption is ~55% and rising with a high failure rate
(~70% of platform teams can't show measurable impact). Read together: **the
market demonstrably wants "declare intent, platform materializes it" and
every attempt so far was a runtime reconciler or a portal, not a compiler.**
Adoption warning from both failures: heavyweight new models die; intent must
compose with K8s semantics (kix's "don't invent new fields" is the right
bet, now with field evidence).

## 4. Tool-history lessons (kubefed → 2026)

Recurring failure modes across the decade, each documented: hub as
SPOF/scale ceiling (kubefed controller; Rancher Fleet's ~100k
BundleDeployment etcd wall; Argo controller sharding pain — every survivor
moved to pull agents); lowest-common-denominator API mirroring (Fed v1
annotations → kubefed `Federated*` wrapping); **CRD interpretation tax**
(any hub that must "understand" resources needs per-type knowledge — Karmada
resource interpreters in Lua/webhooks, Argo health scripts — perpetual
maintenance); status aggregation pain; **silent partial propagation**
(Karmada skips clusters lacking an API version — the runtime version of the
link error kix throws at compile); secret distribution (unsolved by every
tool, always delegated); and "who manages the management cluster."

Two nuances worth keeping honest: Karmada/KubeAdmiral prove hub propagation
*can* work at extreme scale (ByteDance: 10M+ pods, 95-98% unattended
success) **if you staff a platform team to operate a second control plane as
a product** — the honest claim is "config distribution won for everyone
unwilling to do that." And KubeAdmiral's own roadmap names "scheduler
explainability" as its gap — runtime placement's documented weakness is
exactly what compile-time placement resolution fixes.

Interop hooks the ecosystem is converging on, which kix should map onto
rather than duplicate: **ClusterProfile / Cluster Inventory API** (KEP-4322;
the standardized "who are my clusters" object — `kix target probe` should be
able to consume and emit it), the **Work API** shape (won as a concept:
Karmada and OCM both implement it), and **MCS** (§3).

## 5. The top-down inversion — what intent-as-first-class changes

The K8s world is built bottom-up by construction: each cluster accretes
resources; "what is deployed and why" is reconstructed after the fact by
portals (Backstage's catalog drifts because humans maintain it), by
reconcilers (Argo knows *sync state*, not intent), and by tickets. Every
axis of doc 129 inherits this: multi-cluster consistency is checked by
sampling live state; parity is by convention (directory copy); residency is
an audit finding. Compiling top-down inverts the direction of truth — the
consequences, each anchored to a measured pain:

1. **Drift stops being a comparison against convention and becomes a
   comparison against a hash.** 34% of enterprises report compliance
   failures from config drift; the "snowflake cluster" is the named failure
   mode, and vendors sell hourly re-reconciliation as the fix. With a
   content-addressed closure per cluster, "is this cluster what we decided"
   is one hash equality, and *which field, changed by whom* is `kix drift`
   (doc 122) — already built, per cluster. The fleet layer only aggregates.
   This is kix's sharpest commercial wedge into the multi-cluster market.
2. **The catalog is computed, not curated.** The dependency graph, ownership,
   versions, exposure — everything Backstage asks teams to annotate — is an
   *output* of evaluation. A portal over kix renders the graph; it cannot
   drift from it (doc 117's schema-from-options is the same move one level
   down).
3. **Review shifts from artifact diffs to consequence diffs.** Bottom-up
   review reads YAML deltas. Compiled review reads: which clusters change
   (fleet hash set), which packages, blast radius, migration pairs, policy
   verdicts. The reviewer approves *consequences*, most of which (129 §7)
   are closed sets no runtime reconciler can state.
4. **Preview becomes the product.** Crossplane's loudest documented
   criticism: an eventual-consistency loop with **no plan/preview phase** —
   "teams from Terraform miss the diff." The field has explicitly asked for
   compile-then-preview; kix's define → evaluate/check → preview → deploy is
   that answer, extended to fleets.
5. **Silent partials become refusals.** Karmada silently skips a member
   cluster whose API version can't hold the resource; bottom-up systems
   *must* degrade this way because they discover the mismatch at
   propagation time. A compiler holding target axioms (127) refuses at eval:
   "edge-store-047 declares k8s 1.29, this needs 1.31." The whole class
   (silent partial propagation, the recurring failure mode of §4) is
   structurally absent.
6. **Intent survives personnel.** The bottom-up intent record is tribal
   (tickets, Slack, heads). Compiled intent is the repo; `kix explain`-style
   provenance (doc 120) answers "why does this exist on this cluster" by
   graph walk, fleet-wide.

## 6. What maintenance looks like in kix

Day-2 at fleet scale is, per the field: upgrade waves + policy/config sync +
drift reconciliation + cost management. Each becomes a compilation workflow:

**The weekly bump.** Renovate-style input bumps land as PRs; CI rebuilds
only clusters whose activation hash changed; the PR comment is the fleet
diff. Stateless changes auto-merge per policy; stateful ones (migration
pairs) gate on review (doc 91 §8's split, fleet-wide). Maintenance is
mostly *reading closed-set diffs*, not operating clusters.

**K8s version upgrades as target-fact changes.** `k8sVersion` bump in one
target file → legalization re-runs (apiVersion schedule, PSA, deprecations)
→ errors surface at eval, per cluster, before any node is touched. Rollout
is wave-ordered over the fleet (`kix fleet deploy --order` with soak gates)
— the same staged-rollout shape GKE/AKS productized, but where "canary
cluster passed" is backed by artifact identity: staging-eu ran *this hash*,
prod-eu deploys *the same hash modulo declared target deltas*.

**Cluster replacement over cluster surgery.** Blue/green cluster upgrades
are established field practice; content addressing upgrades the pattern
from "stand up a new cluster and hope it matches" to "the new cluster's
activation is provably the old intent compiled against the new target" —
diff is a closed set, migration pairs (doc 67) enumerate the state moves.
Clusters become cattle at the artifact level, not just the node level.

**Policy rollout with proof.** A policy module change (podHardening bump)
compiles fleet-wide; the diff *is* the impact analysis ("weakens 3 workloads
on prod-us, blocked by scorecard"); rollout is per-cluster deploys.
Aggregated Kyverno PolicyReports answer "are we compliant now"; kix answers
"we cannot become non-compliant by construction" plus drift detection for
the runtime remainder. The two compose — kix does not replace admission control (last line
of defense against non-kix actors).

**Cost as a fleet check (new, ranked #1 by the field).** Compile-time
resource-request totals per cluster already exist (capacity-fit, doc 106);
priced against target instance catalogs (127 §9 mineable datasets), the
fleet check reads: "this PR adds ~$1,400/mo across 3 clusters; prod-us
headroom drops below 20%." Estimation, not billing — but it lands where 42%
of enterprises hurt most, at review time instead of invoice time.

## 7. Compiling clouds together

What multi-cloud concretely means under this model — four layers, none of
which is a runtime control plane:

1. **Same intent, N targets** (129 §2): the base module compiles per cloud;
   role resolution absorbs the difference; `kix diff api-eu api-us` states
   the residual. This exists modulo preset corpus.
2. **Cloud services as contract imports.** The boundary to non-K8s infra
   (RDS, VPCs, buckets — Terraform/Crossplane territory) is the same
   contract artifact as §129-4: `kix.importTerraform ./locks/vpc-prod.outputs.json`
   pins a Terraform output set as a passthrough instance. Terragrunt's
   documented failure (live remote-state reads → stale, undeclared coupling)
   is the anti-pattern; the pinned artifact with an update gate is the fix.
   Crossplane compositions can sit on the *provider* side the same way: kix
   consumes their published outputs as contracts, never reconciles them.
3. **Sovereignty as compiled proof.** DORA's concentration-risk framing and
   the EU sovereign-cloud wave make "could you leave your hyperscaler" a
   *regulated* question answered today by essays. A compiler answers it by
   construction: keep a second target (STACKIT/OVH/Hetzner preset) in the
   fleet and **build against it in CI** — the exit plan is a green build
   plus a residency fleet check ("pii packages only on jurisdiction=EU
   targets"), continuously proven, never rehearsed. Nothing in the surveyed
   landscape can state this. Same mechanism, smaller stakes: GPU
   availability (compile the training stack against both CoreWeave and GKE
   targets; capacity chasing then dispatches *within* the pre-compiled set —
   the MultiKueue interop of §8-A4).
4. **What stays out:** cross-cloud runtime traffic engineering (GSLB/mesh),
   billing-grade cost, and infra provisioning itself. Kix compiles what runs
   *on* the clusters and pins contracts to everything else.

## 8. Amendments applied to 129

- **A1 (§6):** slices are generation-atomic; mixing slices from different
  whole-cluster evaluations is refused unless cross-slice contract hashes
  are equal (ThinLTO rider, §2.2).
- **A2 (§4/§10-Q1):** contract artifacts are compiler-emitted and versioned
  glibc-style — provider carries all live versions, consumer lock records
  the linked version, a fleet check forbids dropping a referenced version
  (§2.3-4). MCS API becomes a *lowering target* of the service-shaped
  contracts (§3).
- **A3 (§7):** `kix fleet update-locks` gains policy semantics (bump cadence,
  gates, producer-side notification) — staleness policy is the product
  surface (§2.5).
- **A4 (§8):** the meta-scheduler refusal is scoped to long-lived services.
  Run-to-completion batch/AI dispatch (MultiKueue-style) is legitimate
  dynamic placement: kix compiles the *placement domain* (the candidate
  cluster set + queues), the dispatcher picks within it at runtime. DR
  failover likewise: kix compiles both stances, DNS/operators flip.
- **A5 (§7):** fleet checks gain drift aggregation (the 34% wedge) and cost
  estimation (the 42% #1 pain); the linker gate runs in CI per cluster —
  never a fleet-wide runtime hub (Fleet-etcd/Argo-sharding lesson).
- **A6 (new):** name the fleet layer's one global computation — pin
  coherence — and keep it MVS-simple (§2.1). Map cluster identity onto
  ClusterProfile API; `kix target probe` consumes/emits it (§4).

## 9. New open questions

1. Pin coherence semantics: is fleet-wide version unification a check
   (refuse skew outside a declared window) or a resolver (compute the pin
   set)? MVS says resolver-with-minimal-answers; start as check.
2. Contract version lifecycle: what does deprecation look like ("v1
   referenced by 3 locks, sunset 2026-10") and does the fleet check own it?
3. Does the Terraform/Crossplane contract import stay read-only forever, or
   does kix eventually emit *demands* (a required bucket) that provisioning
   layers fulfill — and is that a contract in the reverse direction?
4. Cost estimation source of truth: instance catalogs are mineable, but
   requests≠usage — is a deliberately rough estimate still a net win at
   review time? (Field says cost is pain #1; even ±30% at PR time beats
   invoice time.)
5. Cell architectures: is "cross-cell traffic prohibited" expressible today
   as a netpol-plugin cluster processor over fleet metadata, making kix the
   first tool to *compile* cell discipline?
