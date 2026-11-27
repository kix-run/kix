# 125: Backup across abstraction levels — state as the contract

**Status:** Brainstorm/RFC — options debate. **Decision deliberately deferred** (Adam,
2026-07-04): the goal of this doc is to keep multiple approaches fleshed out, not to
pick one; the surface decision is blocked on the concrete engine landscape (§4b).
One hard constraint recorded: backup is *declarative input compiling to ready-made
services* — never a CLI action that performs backups.
**Related:** `108_backup_capability_contract.md` (this doc challenges its §4 intent
schema; §2 engine taxonomy and §4.4 scorecard rules survive any outcome),
`112_backup_operationalization.md` (orthogonal — trust loop applies to whatever this
produces), `124_ludo_backup_requirements_and_plan.md` (the empirical driver: best v1
engine was *outside* k8s), `63a_storage_as_cluster_concern.md`, `121_netpol_as_plugin.md`
(the render mechanics), `122_runtime_content_drift.md` (managedFields knowledge),
`67_stateful_migration_orchestration.md` (shared consumer of state facts),
`120_compiler_theory_mapping.md` (the lowering framing).
**Supersedes:** none yet. If the §5 reframe is accepted, 108 §4 gets rewritten and this
doc becomes its predecessor.

## 1. Why reopen this

Doc 108 answered "how does kix wire backup engines." Two things happened since:

1. **Doc 124's empirical finding:** on the real ludo node, every in-cluster engine
   lost — Velero is structurally incompatible with local-path, K8up adds surface
   without safety, and the best capture point was a NixOS systemd unit on the host.
   108's taxonomy cannot even *represent* that engine.
2. **The multi-node question:** the same cluster definition should keep its backup
   guarantees when ludo grows nodes — at which point the host-level trick *stops
   working* (host restic on node A can't see PVCs on node B) and previously
   unavailable options (CSI snapshots, replicated storage with native backup) appear.

Both point at the same structural fact: **the right capture mechanism is a property of
the cluster's shape, not of the workload** — but *what the state is* is a property of
the workload alone. Any DSL that entangles the two picks the wrong owner for one half.

## 2. The level model — what "backup" means where

The same bytes are addressable at many levels. Each level has its own capture
primitive, consistency ceiling, and owner:

| | Level | Unit | Who knows it | Capture primitive | Consistency ceiling |
|---|---|---|---|---|---|
| L5 | Application | "albums", "vault entries" | app / package author | app-native export (`pg_dump`, sqlite `.backup`, HA tar, Immich dump) | transactional |
| L4 | Paths | dirs/files within a volume | package author | file copy with includes/excludes + quiesce hooks | live-read; safe only for write-once or quiesced data |
| L3 | Volume (k8s) | PVC/PV | k8s API | CSI VolumeSnapshot | crash-consistent |
| L2 | Storage service | Longhorn volume, Ceph RBD, ZFS dataset, EBS vol | storage provider | provider-native backup (Longhorn→S3, `zfs send`, EBS snapshot) | crash-consistent |
| L1 | Node / bare metal | host paths (`/var/lib/rancher/k3s/storage`) | node config | host agent (restic/borg/ZFS under systemd) | live-read |
| L0 | Cluster / control plane | etcd, runtime CRs, generated Secrets | k8s | resource export, etcd snapshot | point-in-time |

Observations that any design must honor:

- **Consistency quality peaks at the top; generality peaks at the bottom.** L5 gives
  transactional dumps but exists only where the app offers one. L1 backs up anything
  but reads live files and knows nothing about apps.
- **Levels are alternative capture points for the same state, not layers to back up
  additively.** Backing up a Postgres at L4 *and* L1 gives two corrupt copies, not
  defense in depth. A plan chooses one primary level per state item (belt-and-braces
  = a second *independent* capture, usually L5 logical + one physical level).
- **Cluster shape decides which levels exist.** Single-node k3s/local-path: L1, L4,
  L5 — no L3 (no CSI snapshots), no L2. Multi-node Longhorn: L2, L3, L4, L5 — L1
  becomes incomplete. Managed EKS+EBS: L2/L3 strong, L1 unavailable. **No package can
  know its capture level; no cluster can know what the state is.**
- **L0 is where kix is structurally special.** Velero backs up all cluster resources
  because it knows nothing about their provenance. kix compiles the cluster from git,
  so the backup-worthy remainder at L0 is exactly the **runtime-accreted complement**:
  out-of-band Secrets, operator-created CRs (StackGres's SGBackup metadata — 124
  found these must be exported for DR), dynamically bound PV names. kix can *compute*
  this set — the activation says what it owns; doc 122's managedFields work even
  gives field-level attribution of what it doesn't. Nobody else in the ecosystem can
  enumerate "what k8s state would git not regenerate." This should eventually be a
  compiled artifact regardless of which DSL option wins.

## 3. The state facts only the package author knows

Whatever the wiring looks like, these facts exist and have exactly one truthful
source. Immich as the running example:

```nix
state = {
  media = {
    volume = self.storage;                 # which volume
    paths = [
      { path = "upload";  class = "primary"; }
      { path = "library"; class = "primary"; }
      { path = "profile"; class = "primary"; }
      { path = "thumbs";        class = "derived"; regenerate = "job:thumbnails"; }
      { path = "encoded-video"; class = "derived"; regenerate = "job:transcode"; }
    ];
  };
  database = {
    via = "dep:database";                  # state actually lives in the postgres dep
    export = {                             # L5 capture exists
      kind = "lands-in-path";              # Immich's built-in dump writes into media
      path = "backups";
      schedule-hint = "before:media";      # ordering constraint, not a schedule
    };
  };
  groups.consistency = [ [ "database" "media" ] ];   # capture together, DB first
};
```

The vocabulary: **volume + path classification** (`primary` / `derived` + regeneration
recipe / `cache`), **export** (an L5 capture the app offers: command-with-stdout, or
lands-in-path), **quiesce hooks** (pre/post commands where no export exists —
Vaultwarden's `sqlite3 .backup`), **capture coupling** (Immich's DB-before-files
ordering — real, discovered empirically in 124, modeled nowhere today), **runtime-CR
accretion** (StackGres: "my operator creates SGBackup CRs that are state"), and
**waivers** (`class = "cache"` is 108-Q9's waiver, expressed as a fact rather than an
opt-out).

Note what is absent: schedule, destination, retention, engine, importance-as-policy.
Also note this is *richer* than 108's `{ consistency; importance; }` — that enum
compressed away exactly the facts (paths, hooks, coupling) that 124 needed.

## 4. The options

### A — State declaration + compile-time lowering (the reframe)

Packages declare `meta.state` facts (§3). The cluster declares destinations +
policies (108 §4.2 survives nearly as-is). The compiler **lowers** each state item to
the best capture level the cluster's capability set supports: export/hooks present →
L5/L4 engine; CSI snapshots available → L3; storage provider with native backup → L2;
none of the above but single-node → L1 host agent. Selection is instruction selection
(doc 120's vocabulary); an unsatisfiable requirement (`consistency ≥ transactional`
but no L5 export and no quiesce hook) is a compile error, not a runtime surprise.

- **Multi-node story:** the same package compiles to Longhorn-native backups on the
  3-node cluster and to host-restic on ludo v1. That is the whole kix pitch applied
  to backup: *the definition is portable; the plan is target-specific.*
- **Backup stops being special.** Doc 67 (stateful migration) needs the same quiesce
  hooks and volume facts; doc 111's stateful plan view needs the same classification;
  capacity checks need the sizes. `meta.state` has ≥3 consumers; `meta.backup` has 1.
  Doc 110's lesson ("no meta.X magic, ride standard mechanisms") cuts *for* this:
  backup-the-feature reads a general fact sheet instead of owning a bespoke schema.
- **Cost / risk:** the biggest schema in this space; path declarations can rot when
  upstream apps move directories (a stale `thumbs` exclude silently un-backs-up new
  primary data — mitigation: paths live next to the image version in the same
  package, and L4 engines back up *everything except* declared-derived paths, so rot
  fails safe toward over-backup). Lowering logic is real compiler work.

### B — `kix.backup` builder in the build list (the expose analogy)

`build = [ mainFn (kix.backup { paths = …; hooks = …; }) ]` — the builder declares a
DI arg (the backup capability provider), the evaluator auto-discovers it, the
provider's `out.*` builders render Schedule CRs / annotations inside the owning
instance, exactly how `kix.expose` consumes the gateway.

- **What's right about it:** the mechanics are proven (expose works); resources land
  inside the owning instance, so DAG edges, netpol, and ownership fall out for free;
  the authoring site has natural access to workload context (the pod spec the hook
  must exec into).
- **What's wrong about it:** the analogy breaks on *whose intent it is*. Exposure is
  app intent — a package that wants traffic says so. Backup is **operator policy
  about data the operator would grieve** — the package author "enabling" it inverts
  the responsibility (108's persona table already warned: authors will silently skip
  it; an un-exposed service fails loudly on first use, an un-backed-up volume fails
  silently years later at the worst possible moment). It also can't express
  cross-instance concerns (consistency groups, the L0 complement, cluster-wide
  "everything stateful unless waived") and bakes the capture level into the package
  (the builder renders *this cluster's* engine resources — what does it render when
  the right engine is a NixOS systemd unit?).
- **Salvageable core:** the *surface* is good even if the *semantic* is wrong. A
  build-list entry `kix.state { … }` that declares §3 facts (and gets workload
  context for hook wiring) with **zero resources rendered** keeps B's ergonomics and
  A's ownership split.

### C — 108 as written: `meta.backup` intent + flavor-side sweep

Keep the small enum, collect the matrix post-fixpoint, render per engine. Now
implementable cleanly via doc 121's hooks (`instanceProcessors` /
`clusterProcessors`) instead of a magic post-pass — 121 explicitly generalizes
`findCapabilityProvider` for 108's use.

- **For:** smallest author surface; operator owns enablement; shippable soonest.
- **Against:** the enum is information-destroying — `consistency = "filesystem"`
  cannot express "these two paths are derived," "dump lands here, order matters," or
  "my state is actually in my database dep." 124 hit all three within the *first
  real workload*. C is A with the facts amputated; every amputated fact returns later
  as an annotation escape hatch (`meta.backup.command` already crept into 112 §1).

### D — Backup rides the storage capability (backupClass)

Per 63a, volumes come from a storage provider; give the provider a per-volume
`backupClass` (mirroring storageClass) and let the layer that owns bytes own capture.

- **For:** L2/L3 capture genuinely belongs here — when Longhorn arrives, *its* engine
  is the storage provider; this is the only option where that's structural rather
  than bolted on. K8s-native vocabulary exists (VolumeSnapshotClass).
- **Against as the whole answer:** volumes can't see L5/L4 facts — a backupClass on
  the Postgres PVC yields exactly the crash-consistent-at-best file copy that every
  doc in this corpus warns about; sub-volume path classes and consistency groups
  don't exist at this level; non-volume state (L0 complement) invisible.
- **Verdict:** D is an engine *family* (the L2/L3 backend of A's lowering), not a
  contract.

### 4b — The concrete engine landscape, per level

The surface decision depends on what real engines exist and what each must be told.
Mapping the researched landscape (2026-07, docs 108/124 + session research) against
the levels:

| Level | Engine (health 2026) | Must be told (input facts) | Renders (the "ready-made service") | Cluster prereq |
|---|---|---|---|---|
| L5 | StackGres / CNPG native (healthy) | nothing from the package — operator-native CR injection | backup config inside SGCluster/Cluster CR + WAL archiving | object storage (Garage; MinIO dead) |
| L5 | app dump CronJob (`pg_dump`, `vaultwarden backup`) | export command, creds ref, output contract | CronJob + repo push | none |
| L5 | app-internal schedulers (Immich dump, HA native tars) | enable flag, where output lands | nothing — capture already runs; downstream engine must include the path | none |
| L4 | K8up v2.15 (CNCF, healthy) | PVC selection, `backupcommand` hook, ns | Schedule/Backup CRs, restic repo | none (snapshot-free by design) |
| L4 | VolSync v0.16 (healthy) | per-PVC repo secret + CR; **no hooks exist** | ReplicationSource per PVC | none for `copyMethod: Direct` |
| L4 | plain restic CronJob | paths, excludes, hooks, repo | CronJob | none |
| L3 | Velero v1.18 + CSI (healthy; FSB rejects hostPath/local-path) | PVC selection, pod pre/post hooks | Schedule + BSL + VolumeSnapshots | CSI snapshot class + object store |
| L3 | snapscheduler (backube) | PVC selection, schedule | scheduled VolumeSnapshots (no off-cluster ship) | CSI snapshot class |
| L2 | Longhorn recurring backup | volume selection, schedule | RecurringJob CRs → S3/NFS target | Longhorn (multi-node era) |
| L2 | ZFS send / sanoid, EBS snapshots | dataset/volume identity | systemd units / cloud schedules | ZFS pool / cloud |
| L1 | NixOS `services.restic` (124's pick) | host paths (derived from PVC names), excludes, hooks via kubectl | **NixOS module** — systemd timer | single-node, or per-node completeness |
| L0 | runtime-accreted complement export | the complement set — **computable by kix** | CronJob exporting CRs/Secrets to repo | kix activation knowledge |
| L0 | k3s/etcd snapshot | — | k3s flag / systemd | node config |

The punchline the table forces: **every engine's input needs are a subset of §3's
vocabulary** — volume identity (L2/L3), path classes + hooks (L4/L1), export contract
(L5), the complement (L0). No engine needs schedule/destination/retention from the
package; several need *nothing* from it. Two consequences:

- §3 minimal (volume + path classes + export + hooks) is the **max-flow interface**:
  enough for every engine family; anything less amputates some family (C's enum cuts
  L4/L1 excludes and L5 export contracts).
- The user-facing constraint recorded in the header holds across the board: every
  render output above is a standing service (CR, CronJob, systemd timer) — the only
  inherent *actions* in the whole space are restore and rehearsal (112's verbs),
  never capture.

### E — The backup plan as a compilation artifact (the unorthodox one)

Stop assuming backup wiring materializes as in-cluster resources at all. The compiler
emits a **backup plan** as a distinct artifact of the cluster build: for each state
item, the chosen capture level, the rendered implementation — which may be k8s CRs,
**a NixOS module the node flake imports** (124's engine, made first-class), or a
runbook/script closure for what can't be automated — plus the restore recipe and the
L0 complement export. `kix backup plan` renders it human-readable the way doc 111
renders deploy plans; the trust-loop receipts (112) hang off it.

- **For:** the only option whose *output type* matches reality — 124 proved the best
  engine can live outside k8s; multi-node DR ("restore before the cluster exists")
  is inherently a non-k8s artifact. Extremely kix: the verifiable cluster artifact
  grows a verifiable *recovery* artifact. Demo-able ("your cluster compiles to its
  own disaster-recovery plan") in a way annotations never are.
- **Against:** new artifact kind + consumption path (does the node flake import a kix
  build output? — inverts today's repo layering); risks over-engineering if v1 only
  ever has one engine; doesn't itself answer the intent-schema question (it needs A's
  or C's input to compile *from*).
- **Scoping note (Adam):** the plan must compile to *ready-made services* (CRs,
  CronJobs, systemd timers) — `kix backup plan` as a read/inspect surface is fine,
  but no verb ever performs a capture. Restore/rehearse stay the only actions (112).

## 5. A candidate synthesis — not a decision

Decision explicitly deferred; this section records how the options *compose* if the
facts-reframe wins, so the composition can be attacked as a whole:

The options aren't mutually exclusive; they answer different layers of the question:

1. **Intent layer: A wins on the merits.** State facts are the only stable,
   single-owner, multi-consumer contract. The core reframe: *packages declare state;
   clusters declare policy; the compiler selects the capture level.* "Enabling
   backups" stops being anyone's job — describing state truthfully is the author's
   job (scorecard-enforced when volumes are present), caring about data is the
   operator's.
2. **Authoring surface: B's form, A's semantic.** `kix.state { … }` in the build
   list — expose-like ergonomics, needs workload context anyway for hooks, renders
   nothing.
3. **Render mechanics: C's sweep on 121's hooks.** Engines are plugins consuming the
   compiled state×policy matrix; D's storage providers are one engine family; host
   agents are another.
4. **Output shape: E, scoped down.** No new top-level target in v1 — but engine
   render output is typed as `k8s-resources | node-module | runbook` from day one, so
   the ludo host-restic engine is representable and the "plan" is initially just the
   receipt aggregate (108's `out.backup` per instance) that 112's verbs already read.
   Growing it into a real `kix backup plan` artifact is additive.

The honest counter-position (steelman for keeping 108 as-is): every field in §3 is
speculative until a second real cluster demands it; ludo could ship on C's enum plus
one annotation escape hatch, and the state contract could be extracted *later* from
worked examples rather than designed now. The rebuttal is 124: the first real
workload already needed paths, ordering, an export contract, and a non-k8s engine —
the "later" evidence exists. But the *sequencing* concern stands: implement A's schema
minimally (paths + export + hooks; defer groups, runtime-CR accretion, and the L0
complement compiler to follow-ups) rather than all of §3 at once.

## 6. What happens to 108 if the reframe is accepted

- §4.1 `meta.backup` intent → replaced by `meta.state` / `kix.state` (this doc §3).
- §4.2 `cluster.backup` (destinations/policies/engine matrix) → survives; the matrix
  key changes from consistency-enum to capture-level + requirement matching.
- §4.3 engine contract → survives, plus `renderTarget` typing (§5.4) and a
  `captureLevels` capability declaration.
- §2 taxonomy, §4.4/§5b/§5d/§5e scorecard-alerts-rehearsal-PITR → survive untouched.
- 112 → unaffected (stage model applies to any receipt).

## 7. Open questions (first feedback round recorded 2026-07-04)

1. **The core fork:** facts (`meta.state`, backup as one consumer) vs intent
   (`meta.backup`, 108 §4). *Adam: undecided, not enough context yet — keep both
   fleshed out; the doc's job is the option space, not the pick.*
2. **Surface:** build-list `kix.state { … }` vs plain `meta.state` attrset? *Adam:
   fully dependent on the concrete engine/service landscape — §4b added as that
   input. Next step: pressure-test §4b's "max-flow interface" claim against a second
   real workload (vaultwarden or HA) before deciding.*
3. **Non-k8s render targets** (node-module output for ludo's host engine) in v1, or
   ludo's host restic stays out-of-band per 124? *Adam: unsure on timing, but firm
   constraint: declarative-input-compiling-to-services, never a capture verb. That
   rules out "CLI-driven backup" shapes entirely and makes E's typed render output
   the natural fit whenever it lands.*
4. **Consistency groups** (cross-state capture ordering) — v1 schema or deferred?
   Immich needs only the degenerate in-package case; the scary version is
   cross-instance.
5. **The L0 runtime-accreted complement** — its own doc? It's a backup input here,
   but it's equally a drift/adoption concern (122/116) and arguably a standalone
   differentiator ("kix knows what git won't regenerate").
6. **Does `importance` survive?** The one old-schema field that is intent, not fact.
   *Adam: possibly a package-level × namespace/service-level combination — but
   unsure criticality is useful information at all. Open sub-question: does any
   policy decision actually branch on it that couldn't branch on state class +
   operator match rules instead? If none is found by the time an implementation doc
   is written, drop it.*
