# 90: Ludo as North Star — Ideation & Prioritization

**Status:** Brainstorm
**Related:** `67_stateful_migration_orchestration.md`, `68_migrate_non_kix_live_cluster.md`, `63a_storage_as_cluster_concern.md`, `81_deploy_as_lifecycle_engine.md`, `62_operator_production_implementation_plan.md`, `66_milestone_roadmap.md`, `88b_flux_comparison_and_migration.md`, `business_discussions/25_demonstrator_strategy.md`

---

## Framing

The `ludo` cluster + `demo/deploy-ludo-kind.sh` has served as kix's integration-test-shaped north star. It now works end-to-end: cilium as CNI, auto-derived CNPs, image preloading, cert-manager, immich + vaultwarden reachable. That's the floor. This document enumerates the boundaries worth pushing *next* to mature kix, exercise compiler guarantees, and produce a demonstrator story that maps cleanly onto `business_discussions/25`.

The doc has two sections:

1. **Ideation** — full option space, organized in buckets. The eight seed ideas are called out inline.
2. **Prioritization** — stories and milestones (L1 → Lx) that pick from those options and sequence them for a kind-only horizon followed by on-device hosting.

Off-topic items that surfaced during the discussion and want their own session are captured under **Spin-offs**.

---

## Seed ideas (the original 8)

These were the starting set that kicked off the discussion. They are all kept and assigned to buckets below.

1. **Gateway migration** — disable default ingress, move to Gateway API, both from zero and live from an ingress-running cluster. (Bucket B, not a migration pair — see B.)
2. **Persist the cluster** — move from a throwaway integration test to something under maintenance, stressing `kix health` and `kix diff`. (Bucket C, deferred to on-device horizon.)
3. **Persisting data** — test migration pairs on real storage. (Bucket A.)
4. **Different storage type** — e.g. zpool / ZFS as a cluster storage flavor. (Bucket A.)
5. **Live Postgres-operator migration** — swap Stackgres → CloudNativePG on a running cluster with data. (Bucket A, hardest migration pair.)
6. **Helm parity demo** — show kix-native package is byte-compatible with the upstream chart. (Bucket E.)
7. **Dev / prod split** — two cluster outputs from one flake. (Bucket D.)
8. **Saner production config** — replicas, limits, PDBs, HPAs; today ludo runs on defaults that don't reflect prod. (Bucket D.)

---

## Ideation — full option space

### A. State, storage, data safety

Extends seeds 3, 4, 5.

- **Backup / restore package** (velero or k8up + minio as the object backend). This is the item the user flagged as *most valuable* in the discussion because the ergonomics between engine and packages are still unworked. Questions it forces open: how does a stateful package declare a backup contract? How does the cluster wire a concrete backup impl to satisfy it? What does a restore look like through the DI graph, not through a runbook?
- **ZFS / zpool storage flavor** for ludo. Makes `63a_storage_as_cluster_concern.md` real — a second storage provisioner proves the cluster-as-owner framing holds, and drives the first honest hardware profile for the on-device horizon. (Seed 4.)
- **Storage-class swap as migration pair** — ludo phase 1→2 from `67_stateful_migration_orchestration.md`. `local-path` → `zpool`. Smallest migration-pair exercise: same package, same dep slot, stateful, different backing. Needs backup in place as a precondition.
- **Live Postgres-operator swap (Stackgres → CNPG)** (seed 5). The hardest migration pair: two operators with different CR schemas, different replication primitives, different backup stories. Forces `67` out of "PVC swap" mode and into "whole stateful subsystem swap" mode. Requires backup/restore and a validated migration-pair runtime first.
- **Postgres major version bump with on-disk migration** — exercises waves, verdicts, pre/post hooks (`81_deploy_as_lifecycle_engine.md`) without changing the operator. Natural stepping stone to the CNPG swap.
- **Rename instance / namespace as a first-class migration pair** — today both are fatal in K8s. The user called this out as a good catch. The compiler already sees the identity change; the question is whether it refuses, offers a pair, or requires an explicit `moved {}` declaration (see ROADMAP line 142 on `moved` for the DSL shape).

### B. Networking, gateway, security

Extends seed 1.

- **Gateway migration, zero-install**. Disable default ingress in ludo-kind, deploy Gateway API + provider (cilium-gateway or envoy-gateway), produce HTTPRoutes for immich and vaultwarden. Gateway package is already shipped (archived `70`), so this is a cluster-configuration move, not engine work. The points the user flagged as important:
  - Deploy/prune order: Gateway CRDs and controller must come up before routes; old ingresses must be pruned without dropping traffic. Pure lifecycle-engine territory.
  - Switching the *kind* capability: the cluster currently advertises ingress as its HTTP-ingress capability. Moving to Gateway means rewiring which capability the cluster satisfies, which every consumer then targets through DI. This capability flip wants its own design session.
  - *Not* a migration pair. Nothing is stateful, so swapping activations is fine. Gateway migration tests deploy/prune semantics and capability switching, not 67.
- **Gateway migration, live from ingress** — same flow but with ingresses already deployed (via kix). Contrast the diff, show the capability switch, let the lifecycle engine handle the overlap window. A much stronger story than the zero-install version and is where `81` earns its keep.
- **Default-deny egress** via auto-derived CNPs, gated on `cilium connectivity test`. The generated CNP is currently permissive enough that this has not been pushed. Tightening it is the first honest correctness claim for DI-derived network policy.
- **Real TLS in kind** via cert-manager + pebble / letsencrypt-staging, so the demo shows HTTPS login pages instead of HTTP. Cheap, visible payoff.

### C. Persistence of the cluster as a maintenance target

Extends seed 2. Deferred to the on-device horizon per the user.

- **Run ludo for weeks**. Scheduled `kix diff` and `kix health` against it; surface drift over time. This is what promotes the operator docs (`62`, `81`) from "design" to "proven".
- **Drift injection** — `kubectl edit` a Deployment, verify `kix diff` flags it with the right blast radius.
- **Upgrade cascade**. The user flagged this as a *very good* idea. Bump kind node image → bump cilium → bump postgres → watch the DAG reason about order, verdicts, and cross-package compatibility. This is also where *package cross-compatibility* surfaces as a first-class concern: bumping one package must be evaluated against every consumer's `meta.compatibleWith`, and the compiler should narrate the decision. Depends on the upgrade cascade running on a cluster that actually lives long enough to need upgrades — so it rides with on-device hosting.
- **Pause and resume** — shut the cluster down for a day, rebuild, reconcile. Tests reproducibility *and* operator resync behavior.
- **Chaos-lite** — randomized pod and node kills, watch kix health and the operator stay sane.

### D. Dev / prod and config maturity

Extends seeds 7 and 8. The user wants to *explicitly* test multiple env-stamping strategies, not just one.

- **Two outputs from one flake**: `ludo-dev` (kind, minimal replicas, ephemeral storage, mailhog, default-deny off) and `ludo-prod` (realistic profile: replicas, PDBs, resource limits, HPAs, backups, monitoring, default-deny on). This is the "cleanest separation" baseline.
- **Namespace-prefixing / stamping as an alternative** — same physical cluster, two logical envs via `mkEnv` or an equivalent prefix mechanism. Exercises a different part of the DSL and validates that env boundaries don't have to be cluster boundaries. The user wants both approaches tested so the tradeoffs are understood empirically, not just on paper.
- **Saner prod defaults by construction** — package-level options for replicas, limits, PDBs, HPAs driven by the active profile, not hand-tuned per cluster. (Seed 8.)
- **Capability-based preflight for the prod profile** — the compiler *refuses* to eval `ludo-prod` if any stateful package has no backup wired, or if the storage class is ephemeral, or if replicas < 2 on a capability-flagged-HA service. Turns seed 8 from a docs item into a compiler guarantee.
- **Per-env scorecard rules** — "replicas=1 is a warning in dev, fatal in prod" as a scorecard rule shipped alongside the package. Pairs with `60_scorecard_rules_design.md` (archived, reference).

### E. Adoption / migration story — parity clusters

Extends seed 6. The user notes this is a lot of work because every story in this bucket requires standing up a parity cluster in the alternative technology. Not immediate; noted for later.

- **Helm-to-kix adoption on ludo** — stand up immich / vaultwarden via upstream Helm charts first, take a diff, then kix-adopt them in place via `mkImport` + Helm-compat labels (ROADMAP line 140). Diff should shrink to near-zero. This is the reference implementation of `68_migrate_non_kix_live_cluster.md`.
- **Flux-to-kix migration** — analogous, promotes `88b_flux_comparison_and_migration.md` from design to demonstrated.
- **Helm parity demo** (seed 6) — pick `kube-prometheus-stack` or similar, show a running prod cluster can flip to the kix-native package without workload churn. Hardest story in the bucket, highest business value because it is literally the migration pitch.

### F. Packages the demo needs

Not directly on the seed list, but prerequisites for several A-bucket items.

- **Monitoring stack live on ludo** — `kube-prometheus-stack` package exists; turn it on, point grafana at it, show package-level dashboards. Feeds `interesting_thoughts/49_topology_aware_monitoring.md`.
- **Object storage (minio)** — prerequisite for velero, for CNPG backup-to-S3, and for an external immich library. One package unlocks three demos.
- **Mail (mailhog in dev, postmark-ish in prod)** — enables the "abstract contract, different impl per env" compiler demo in bucket D.

### G. Compiler / DSL guarantees to stress

- **Typed lifecycle tags enforcement** — "stateful package requires a backup contract" refusal at eval time. Builds on the existing `meta.lifecycle = "stateful"` (ROADMAP line 136).
- **Cross-package capability contracts** — "immich requires smtp" satisfied by the mail package's advertised capability; compile error otherwise. Same framing as the existing extension validation.
- **Resource identity pinning / rename detection** — detect rename-through-eval (fatal in K8s), force the user to opt into a migration pair or declare `moved {}`. The user flagged this as a new idea worth pushing to ROADMAP on its own. Separately tracked in the roadmap addition.
- **Wave ordering proofs** — run `81`'s Transition plan across a cascade and display the DAG. Visible payoff for the lifecycle engine work.
- **Exact rollback check** — apply a change, apply its inverse, assert content-hash parity across the cluster. Regression test for the whole pipeline.

### H. Operator in the loop

The user likes this but flagged moving ludo to the operator as a big step that deserves its own re-ideation session once we are closer. Noted for follow-up; keep the options here lean.

- **Self-hosting** — ludo's operator deploys ludo itself. `89_eval_operator_mode.md` (interesting thought) is the lean variant; `62_operator_production_implementation_plan.md` is the production path.
- **PR-driven flow** — value edit in a branch, operator picks it up, narrates the diff.
- **Operator status as first-class UX** — ludo's homepage surfaces a green/yellow/red cluster verdict served by the operator.

**Follow-up:** when we start planning the ludo-on-operator move, re-run this ideation for H to surface ideas we cannot see clearly from the pre-operator vantage point.

### I. Storytelling / distribution

The user's concern: kix is evolving fast alongside ludo, so any static artifact (VHS, screencast) rots. Options:

- **Devlog-first** — each ludo phase transition produces a blog post via the `update-dev-blog` skill. Text ages better than video and is cheap to refresh.
- **Replayable artifacts for stable versions** — once a ludo phase is "blessed" against a tagged kix version, cut a screencast / VHS pinned to that version. Older tapes stay honest because they declare their kix tag.
- **Start concrete** — the first artifact worth producing now is a recording of `deploy-ludo-kind.sh` as-is, narrated, showing the current north-star baseline. Everything after that is a delta.
- **More than VHS** — real browser + terminal + cluster-state splits; VHS alone is too thin for a cluster story. Likely a tmux-multiplexed recording with kubectl views alongside kix CLI output.

---

## Spin-off sessions (captured, not prioritized here)

These came up during the discussion as topics that *touch* ludo but deserve their own thinking. Not in this doc's prioritization.

- **DR in the kix model.** Backup/restore has obvious package-level ergonomics, but disaster recovery as a whole (restore-to-new-cluster, cross-region, RTO/RPO promises) is a separate story — kix's role versus a dedicated DR operator is the real question.
- **Gateway API as a kind-capability switch.** How the cluster changes which capability it advertises (ingress → gateway) at eval time, and how consumers reason about it, wants its own design pass independent of the ludo migration demo.
- **Supply chain as maintenance.** Not just provenance and compliance exports (shipped: `60`, `61`) but the *maintenance* half — upgrade cadence, CVE tracking, sign-and-rotate, nixpkgs bump pipelines — as an actively managed concern. Ties to archived `26_images-vertical-integration.md` and `interesting_thoughts/54_activation_signing.md`, but the maintenance framing is new and deserves its own doc.
- **Re-ideation for ludo-on-operator (bucket H).** Before committing to move ludo onto the operator, re-run this brainstorm with the operator as the substrate — the option space changes meaningfully.

Two items the user asked to drop into `ROADMAP.md` rather than live here:

- **Nightly eval-time bench.** Fail CI if eval time regresses > X%. Not ludo-specific; general protection for the "eval times" risk in ROADMAP.
- **Resource identity pinning / rename detection.** Compiler guarantee, not a ludo-specific demo.

---

## Prioritization

Stories are the unit, not features. Each story is one or two buckets combined into a thing a reader would actually follow. Stories are grouped into horizons by whether they can ship on the current kind-only substrate (L1–L3) or need the on-device horizon (L4+). Within a horizon, stories are ordered by dependency, not by value — a later story assumes earlier stories landed.

### Horizon 1 — kind-only, next few weeks

Constraint: ludo still runs as `deploy-ludo-kind.sh`. The goal before moving on-device is to build *production trust* — the compiler, the packages, and the deploy pipeline should already enforce the production story inside kind, even though we are still throwing the cluster away.

**L1 — "Production-shaped from one flake"**
- D: two outputs (`ludo-dev`, `ludo-prod`) from one flake.
- D: namespace-stamping variant as a second env-boundary strategy, both exercised.
- D: saner prod defaults by construction (replicas, PDBs, limits, HPAs driven by profile).
- D: capability-based preflight — `ludo-prod` refuses to eval on an ephemeral storage class or on a stateful package without a backup contract.
- Seeds covered: 7, 8.
- Why first: every downstream story benefits from the prod/dev axis existing, and the preflight gives the compiler a job it does not have today.

**L2 — "Backup is a package contract, not a runbook"**
- F: minio package (object storage prerequisite).
- A: backup / restore package with package-level contract. Ergonomics work — how a stateful package declares `requires backup`, how the cluster wires a concrete impl, what a restore looks like through DI.
- G: typed lifecycle enforcement — prod refuses to eval without a satisfied backup contract (closes the loop from L1).
- F: monitoring stack live so backups and restores produce visible signal.
- Seeds covered: — (adds the missing prerequisite for 3 and 5).
- Why second: the user called this the highest-value item and it gates every storage and migration story.

**L3 — "The first real migration pair"**
- A: ZFS / zpool storage flavor (ludo hardware profile gets its first realistic storage tier).
- A: storage-class swap as migration pair (`local-path` → `zpool`) — ludo phase 1→2 from `67`.
- A: rename instance / namespace handled as a migration pair, not a fatal error. Compiler refusal without `moved {}` or equivalent.
- G: wave ordering proof printed during the transition, driven by `81`.
- Seeds covered: 3, 4.
- Why after L2: a migration pair without a verified backup is a foot-gun, and the user agreed migration pairs should not run without one.

**L-between — "Gateway without stateful baggage"** (can interleave with L3, no dependency)
- B: disable default ingress, deploy Gateway API + provider, HTTPRoutes for immich and vaultwarden.
- B: live gateway migration from ingress-running cluster; prune old ingresses via lifecycle engine.
- B: real TLS via cert-manager + pebble / letsencrypt-staging.
- B: default-deny egress gated on `cilium connectivity test`.
- Seeds covered: 1.
- Not a migration pair; tests deploy/prune semantics and capability switching only. The kind-capability switch question is spun off to its own session.

### Horizon 2 — on-device hosting, once production trust is established

Ships once ludo moves off kind onto real hardware. Everything here assumes the cluster is long-lived.

**L4 — "The cluster lives"**
- C: run ludo continuously, scheduled `kix diff` and `kix health`, recorded drift over time.
- C: drift injection test — `kubectl edit` a Deployment, verify blast-radius reporting.
- I: start producing devlog posts per phase transition, plus a first screencast pinned to the current kix tag.
- Seeds covered: 2.
- Why first in H2: makes every following story testable against an actually-alive cluster.

**L5 — "Upgrade cascade"**
- C: upgrade cascade — bump kind/node image, cilium, postgres; the DAG narrates order and cross-package compatibility.
- C: package cross-compatibility enforcement driven by existing `meta.compatibleWith` + verdicts, surfaced during the cascade.
- G: exact rollback check — apply cascade, apply its inverse, assert content-hash parity.
- Seeds covered: — (the user flagged upgrade cascade as a very good, orthogonal idea).
- Why: upgrade cascade is the most compelling maintenance story and the clearest compiler-versus-kubectl contrast. Also the point where package cross-compatibility stops being hypothetical.

**L6 — "The hardest migration pair"**
- A: Postgres major-version bump with on-disk migration (prep step).
- A: live Stackgres → CNPG operator swap on a running cluster with data. Requires L2 backup, L3 migration-pair runtime, and L5's upgrade cascade plumbing.
- G: capability contract for `provides: postgres` satisfied by two different impls, validated at eval.
- Seeds covered: 5.
- Why: this is the most stressful test of `67` and the most valuable migration story for the business case — but it is also the most brittle one, and should only run after backup, migration pairs, and upgrade cascade are trusted on a live cluster.

**L7 — "Move ludo onto the operator"** *(pre-gate: re-run this ideation for bucket H)*
- H: ludo deploys ludo via the operator (`62` production path or `89` eval-operator variant, decided in the re-ideation session).
- H: PR-driven flow with operator narration.
- H: operator verdict as ludo's homepage.
- Why: the user marked this as a big step deserving its own brainstorm. Sequenced after L4–L6 because the operator takes over a cluster that *already* survives maintenance, so L4+L5 derisk it.

### Later / optional horizon (parity work)

Not scheduled; flagged as "a lot of work, not immediately concerned".

**L8 — "Parity story"**
- E: Helm-to-kix adoption on ludo (reference implementation of `68`).
- E: Flux-to-kix migration (promotes `88b`).
- E: Helm parity demo on `kube-prometheus-stack` or similar.
- Seeds covered: 6.
- Cost: standing up parity clusters in each alternative stack. Worth it for the business case, not worth it for the compiler.

### Not in this doc (tracked elsewhere)

- Nightly eval-time bench → `ROADMAP.md`.
- Resource identity pinning / rename detection → `ROADMAP.md` (the rename detection angle is the new part).
- DR, gateway kind-capability switch, supply chain as maintenance, H re-ideation → spin-off sessions.

---

## Open questions to resolve before L1 lands

1. Which env-stamping strategy do we ship as the *default* recommendation after L1 — separate outputs or namespace-stamping? The L1 story exercises both; the answer is the L1 retrospective's deliverable.
2. What does "backup contract" look like syntactically in the package? Option shape, scope (`meta` vs `out`), and whether it is satisfied by a cluster-level wire or a per-package explicit choice. This is the open question L2 has to answer before it can ship.
3. How does the capability-based preflight in L1 surface errors? Fatal at eval, structured diagnostic per `80_structured_diagnostics.md`, or both? Likely both, but the phrasing matters for the first prod-refusal a user sees.
4. What does `moved {}` look like in the DSL for the rename case in L3? ROADMAP line 142 has the seed; it needs fleshing out.
