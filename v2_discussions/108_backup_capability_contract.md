# 108: Backup as a Capability Contract

**Status:** RFC — Draft
**Relevance:** Active — blocks doc 105 §B1, doc 90 §L2, doc 106 §1.2 (`kix restore`).
**Related:** `105_ludo_homelab_operational_readiness.md` §A2/§B1, `90_ludo_north_star_ideation.md` L2, `106_ops_lifecycle_verbs_and_capacity_check.md` §1.2, `63a_storage_as_cluster_concern.md` (layering precedent), `97_service_contract_primitives.md` (capability-contract pattern), `95_netpol_build_time_validation.md` (validation pattern), `101_monitoring_provider_landscape.md` / `102_auto_monitoring_wiring.md` (closest analogue), `65_passthrough_instances.md` (off-cluster targets), `67_stateful_migration_orchestration.md` (restore as a shape of migration).

---

## 1. Problem

A stateful workload's PVC is a load-bearing object. Today kix has **nothing structural about backup** — packages declare PVCs, the cluster operator hopes someone wrote a runbook. Three things follow from that gap:

1. **The compiler can't refuse a known-bad shape.** A `meta.lifecycle = "stateful"` package with no backup wired evaluates fine. Doc 90 §L1 wants `ludo-prod` to refuse exactly this; doc 106 §2.5 wants `architecture.statefulNeedsBackup` at error level on single-node clusters.
2. **`kix restore` (doc 106 §1.2) has nothing to call.** It's specified against a hypothetical `engine.out.restore` convention that no engine implements yet.
3. **Engine choice leaks into packages.** Today if you wanted CNPG-managed backups for a Postgres, you'd put the schedule and S3 ref into the package itself. That conflates "I am stateful, I need backup" (package author's concern) with "back this up to s3://homelab-backups every night, retain 30 days" (cluster operator's concern). Doc `63a` already established this layering for storage class — backup needs the same treatment.

The repo today has `kix/packages/velero/` and `stackgres-cluster` (which has its own backup config block), but no shared contract. They cohabit, they don't interoperate.

---

## 2. Engine taxonomy

Three families of backup engine, with materially different ergonomics. The contract has to span them.

### 2.1 Application-aware (the gold standard)

Examples: **CNPG** `bootstrap.recovery` + scheduled WAL/object backups, **StackGres** `SGObjectStorage` + `SGBackupConfig`, **etcd** snapshot + restore, **Redis** RDB/AOF dumps, **Loki** boltdb-shipper to object storage.

- Operator already understands consistency (quiesce, hot backup, WAL, point-in-time recovery).
- Restore is *also* operator-native: emit a fresh CR with `bootstrap.recovery`, the operator does the work.
- Backup target is typically S3-compatible.
- **What kix needs to express:** a wiring between the workload's CR and the backup destination, plus schedule/retention. The engine *is* the package.

### 2.2 CSI-snapshot-based (Velero pattern)

Examples: **Velero** + CSI VolumeSnapshotClass, **Stash** (k8up's predecessor), cloud-provider snapshot operators.

- Storage-driver-level: snapshots PVCs via the CSI snapshot API, then ships the snapshot off-cluster (Velero uploads it to object storage).
- Application-agnostic but *requires* CSI driver support for snapshots. `local-path` (k3s default) does **not** support snapshots — Velero falls back to restic/file-copy mode for those, which is no longer crash-consistent.
- Restore re-creates the PVC from the snapshot manifest. Workload still has to be quiesced or it must tolerate restart.
- **What kix needs to express:** "every PVC tagged `meta.backup` participates in the cluster Velero schedule," plus `BackupStorageLocation` wiring. The engine is *cluster-level*, not per-package.

### 2.3 Generic file-level (restic / k8up / kopia)

Examples: **restic**, **k8up** (operator wrapping restic), **kopia**, plain `pg_dump | restic backup -`.

- File-level. No CSI dependency. Works on `local-path`. This is what the ludo homelab needs **today** — see doc 105 §A2.
- Crash consistency depends on whether the workload tolerates a live read of its data dir (Postgres does not; SQLite/file-PVCs typically do).
- For DBs you compose: `pg_dump → restic` (logical) rather than `restic /var/lib/pg` (physical, broken).
- **What kix needs to express:** a sidecar/CronJob per PVC, restic repository config, and (for DBs) a hook to run a logical-dump command instead of raw file copy.

### 2.4 The dimension that matters

| Engine family | Granularity | Off-cluster target lives where? | Restore primitive | Single-node OK? |
|---|---|---|---|---|
| App-aware | Per-instance CR | Operator config (S3 bucket) | New CR with `bootstrap.recovery` | Yes |
| CSI/Velero | Per-PVC | Cluster `BackupStorageLocation` | New PVC from `VolumeSnapshot` | Needs CSI snapshots |
| restic/k8up | Per-PVC or per-command | Repo URL on Schedule CR | `restic restore` Job | Yes |

A real cluster runs **all three at once**: CNPG handles the Postgres, k8up handles the file PVCs, Velero handles the cluster-wide DR snapshot. The contract has to dispatch on what the resource *is*.

---

## 3. Personas

### Package author (Lucas writing `kix/packages/immich/`)
- **Wants to say:** "I have a PVC at `/data` that holds user photos. It is durable state."
- **Does not want to know:** which engine the cluster uses, S3 endpoints, schedules, retention, what restic is.
- **Knows things only they know:** for app-aware engines, what a *consistent* dump looks like (Immich has nothing special; Postgres does).
- **Concern:** if the contract requires too much per-package boilerplate, packages will silently skip it.

### Cluster operator (Ludo wiring `clusters/ludo/`)
- **Wants to say:** "Backup destination is `restic:/srv/backup`. Schedule daily at 02:00. Retain 30 daily, 12 monthly."
- **Wants the compiler to enforce:** if any `meta.lifecycle = "stateful"` package is unmatched by a backup intent, refuse to build `ludo-prod`. (Doc 90 §L1 D, doc 105 §B1.)
- **Concern:** mixing engines per cluster (CNPG for PG, k8up for file PVCs, Velero for DR) without writing wiring twice.

### Solo / homelab operator (the doc 105 persona)
- **Wants:** "the simplest thing that works on a single k3s node with one external HDD." restic-to-local-disk now, restic-to-Hetzner later, **without rewriting anything**.
- **Concern:** doesn't trust untested backups (and shouldn't). Wants `kix restore` to be a real verb, not a runbook.

### Multi-tenant platform team
- **Wants:** namespace-scoped backup policies, per-tenant retention, cost attribution per backed-up GB, repo isolation between tenants (one tenant's restic key can't read another's).
- **Concern:** "the cluster operator picks one engine globally" doesn't fit. Need per-package or per-instance override.

### Compliance-driven enterprise
- **Wants:** RPO/RTO declared and *checked*; encryption-at-rest provable; off-region copy provable; immutable / object-lock buckets; audit trail of every restore.
- **Concern:** today `meta.backup = true` proves nothing. Wants the contract to surface the *evidence path* (which engine, which destination, last-success timestamp) into the scorecard / compliance export (`archive/61_compliance_exports.md`).

### Developer in CI (`ludo-dev` on kind)
- **Wants:** the prod-shaped contract to **noop or use a tmpfs backup** so kind clusters don't try to mount an HDD. Same `meta.backup` declarations, different cluster-side wiring.
- **Concern:** if dev needs different package code, the contract has failed.

---

## 4. Proposal

Backup is a **typed DI capability** wired by the cluster, exactly like storage in `63a` and monitoring in `101/102`. Three pieces.

### 4.1 Package side: `meta.backup` intent

A package author declares intent on resources or instances they own:

```nix
# inside a package's resources block
self.pvc = scope.mkPVC {
  meta.backup = {
    consistency = "filesystem";  # "filesystem" | "app-aware:postgres" | "app-aware:etcd" | …
    importance  = "critical";    # "critical" | "important" | "ephemeral"
  };
  spec.resources.requests.storage = "100Gi";
};
```

Or on the instance root, when the engine is operator-native and the PVC isn't directly visible (StackGres/CNPG case):

```nix
# kix/packages/stackgres-cluster/default.nix
out.meta.backup = {
  consistency = "app-aware:postgres";
  importance  = "critical";
  # The engine knows how to back itself up; advertise the hook.
  via = self.sgCluster.out;   # the resource the engine wires backup config into
};
```

**Fields, deliberately small:**
- `consistency` — the only thing the package author actually knows. Drives engine selection at the cluster.
- `importance` — coarse priority. Lets the cluster apply different retention/schedule to "critical" vs "important". Not a literal frequency — the package shouldn't pick that.
- `via` (optional) — for app-aware engines, which resource carries the engine-side backup config.

**No fields the package author shouldn't know:** schedule, retention, destination, encryption, compression, repo URL.

### 4.2 Cluster side: a `backup` flavor / capability

The cluster operator chooses an engine per `consistency` class:

```nix
# clusters/ludo/storage.nix
cluster.backup = {
  destinations.primary = {
    kind = "restic";
    repo = "/srv/backup/restic";
    encryption.passwordRef = secrets."backup-restic-password";
  };

  policies.default = {
    schedule  = "02:00";
    retention = { daily = 30; weekly = 12; monthly = 6; };
    destination = "primary";
  };
  policies.critical = {
    schedule  = "@every 6h";
    retention = { daily = 60; weekly = 24; monthly = 12; };
    destination = "primary";
  };

  engines = {
    "filesystem"           = packages.k8up;       # PVC-level via restic
    "app-aware:postgres"   = packages.cnpg;       # operator-native; or stackgres for SG clusters
    # CSI snapshot / Velero plugged in here when the cluster has snapshot-capable storage
  };
};
```

The cluster's storage flavor (per `63a`) reads the matrix of `meta.backup` intents from the resolved instance graph and:

1. Picks the engine via `engines.<consistency>`.
2. Picks the policy via `importance → policies.<…>` (sane defaults map).
3. Renders engine-specific resources: `Schedule` CRs for k8up, `BackupStorageLocation` + `Schedule` for Velero, `SGObjectStorage` for StackGres, `Cluster.spec.backup` for CNPG.
4. Stamps `out.backup` on each backed-up instance — the *receipt*, not the intent — so downstream verbs (`kix restore`, scorecard rules, monitoring) can find it.

### 4.3 Engine side: contract the engine package implements

A package may declare itself a backup engine by exposing:

```nix
# kix/packages/k8up/default.nix
out.backupEngine = {
  consistency = [ "filesystem" ];
  # Render backup-side resources for a list of targets.
  render = { targets, policy, destination }: …;   # → resource set
  # Render restore-side activation for a single target at a point in time.
  restore = { target, point }: …;                 # → activation closure (per doc 106 §1.2)
};
```

`out.backupEngine.restore` is the convention doc 106 §1.2 already specifies — this RFC names it and gives every engine a place to put it. Engines that don't support restore (yet) declare so explicitly so the cluster fails-fast at eval, not at incident time.

### 4.4 Build-time validation (per doc 95 pattern)

Two scorecard rules:

- `architecture.statefulNeedsBackup` — every instance with a PVC or `meta.lifecycle = "stateful"` must resolve to a `meta.backup` intent **and** the cluster must have an engine for that consistency class. Default `warning`; `error` under the `single-node` module (doc 106 §2.5).
- `architecture.backupHasRestore` — every chosen engine must implement `restore`. Hard error: a backup you can't restore is theatre (doc 105 §A2 line).

A third, looser rule lives in `interesting_thoughts/`-territory:

- `architecture.backupRehearsed` — last successful kind-restore rehearsal within N days. Requires activation history (doc 106 §1.5) + a way to record rehearsal results. Skip for v1.

---

## 5. How the personas land

| Persona | Writes | Gets |
|---|---|---|
| Package author | `meta.backup = { consistency = "filesystem"; importance = "important"; }` on the PVC. | No engine-specific code. Will compile against any cluster that wires *some* engine for filesystem. |
| Cluster operator (homelab) | `cluster.backup = { destinations.primary = restic-local; engines.filesystem = k8up; engines."app-aware:postgres" = stackgres; }` | Velero, k8up Schedules, SGObjectStorage all rendered. |
| Solo/homelab | Same as above with `restic-local`; later swaps `destinations.primary.kind = "restic-s3"`. | No package-side change when destination moves off-node. |
| Multi-tenant | Override `engines` / `destinations` per namespace flavor; per-tenant restic repo. | Namespace isolation; one tenant can't decrypt another's repo. |
| Enterprise/compliance | Adds `policies.critical.destination = "primary-immutable-eu-west"` + `policies.critical.encryption.kms = ...`. Scorecard rule promoted to error. Compliance export reads `out.backup` receipts. | Provable evidence trail per resource. |
| Dev/CI | `cluster.backup.engines.filesystem = packages.no-op-backup` in `ludo-dev`. | Same packages compile, no HDD touched. |
| `kix restore` (doc 106) | — | Calls `instance.out.backup.engine.out.backupEngine.restore { target; point; }` and produces a separate Activation. The convention finally has an implementation. |

---

## 5b. Alerting integration (sizing + failures)

A backup contract that doesn't surface failures is the same theatre doc 105 §A2 warned about. Two alert classes, both auto-derived from `out.backup` receipts the same way doc 102 auto-wires monitoring.

**Failure alerts (correctness):**
- `BackupNotSucceededRecently` — last successful run older than `policy.schedule × 1.5`. Source metric is engine-specific (k8up `k8up_jobs_succeeded_count`, Velero `velero_backup_last_successful_timestamp`, CNPG `cnpg_backup_last_completed_timestamp`, StackGres status condition). Engine declares the metric path in `out.backupEngine.metrics`; the cluster renders one PrometheusRule per receipt with the right query bound.
- `BackupFailing` — N consecutive failures (cheap signal — fires before the staleness alert in the common case).
- `RestoreCapabilityMissing` — engine reports its `restore` path is unavailable (e.g. destination unreachable, credentials rotated). Cheaper to detect at scrape time than at incident time.

**Sizing alerts (capacity):**
- `BackupRepoNearFull` — destination usage > 85%. Per-destination, not per-receipt. Restic/k8up expose repo size; Velero `BackupStorageLocation` doesn't natively, so the engine's metrics block declares either a metric or a "no sizing signal — recommend external bucket alarm" gap.
- `BackupGrowthAnomaly` — daily delta > N× the trailing 7-day median. Catches "someone enabled debug logging into a backed-up PVC" before the repo fills.
- `RestoreTimeBudgetExceeded` — projected restore time (repo size ÷ measured restore throughput from last rehearsal) exceeds the policy's RTO. Requires §5d.

**Where this lives.** Each engine's `out.backupEngine` grows a `metrics` block (Prom queries by symbolic name: `lastSuccess`, `failureCount`, `repoSizeBytes`, `restoreThroughputBytesPerSec`). The cluster's monitoring flavor (doc 102) reads the matrix of receipts and renders a `PrometheusRule` per receipt + per destination, plus an alert pack entry per shape. The baseline alert pack from doc 105 §A3 item 7 ("Last successful backup older than configured RTO") becomes the *default* generated by this machinery rather than a hand-rolled rule.

**Open questions deferred:** notification routing (ntfy vs. PagerDuty), per-importance routing (`critical` → wakeup, `important` → email digest) — those are doc 102 / Alertmanager-routing concerns, not this RFC.

---

## 5c. Annotation stamping — `crd.mkBackedUp` / engine adapters

Several engines drive backup off **annotations on the workload**, not separate CRs:
- Velero looks at `backup.velero.io/backup-volumes` (opt-in restic mode), `pre.hook.backup.velero.io/command`, `post.hook.…`, `velero.io/exclude-from-backup`.
- k8up reads `k8up.io/backup` (resource selector) and `k8up.io/backupcommand` (the per-pod logical-dump command).
- StackGres puts backup config inside the `SGCluster` body; CNPG inside `Cluster.spec.backup`.

If every package author had to remember which annotation goes where, the contract leaks the engine choice back into packages — exactly what §1 ruled out. We need a stamper.

**Proposal: `crd.mkBackedUp` (or `scope.mkBackedUp`)** — a small builder the storage flavor calls *after* engine selection, given the resource and the resolved receipt:

```nix
# pseudo, called by the flavor render step
out.resources = mapAttrs (name: r:
  if r ? meta.backup
  then crd.mkBackedUp { resource = r; receipt = receipts.${name}; engine = …; }
  else r
) out.resources;
```

`crd.mkBackedUp` dispatches on `engine.out.backupEngine.annotationProfile`:
- `velero` → stamps `backup.velero.io/backup-volumes`, lifts `meta.backup.preHook` to `pre.hook.…`.
- `k8up` → stamps `k8up.io/backup=true`, lifts `meta.backup.command` (for app-aware dumps) to `k8up.io/backupcommand`.
- `cr-injection` (StackGres/CNPG) → no annotations; instead patches the operator-CR body via the engine's known field path.
- `none` → noop (e.g. CSI-snapshot-only path doesn't need workload-side stamping).

**Why a primitive, not freeform `meta.annotations`.** The DSL principle "don't invent new fields" applies in reverse here: there's no clean K8s-native way to say "backup this", so the engines invented their own. We need *one* kix-side surface that hides the dialects, and one place where mistakes (typo'd annotation key, wrong namespace for the hook) get caught at eval. A builder also gives us the receipt-stamping site — `out.backup` is set in the same place — so the receipt and the annotations can never disagree.

**Engine contract addition (extends §4.3):**

```nix
out.backupEngine = {
  consistency       = [ "filesystem" ];
  annotationProfile = "k8up";          # | "velero" | "cr-injection" | "none"
  crFieldPath       = null;            # for cr-injection: e.g. ["spec" "backup"]
  metrics           = { … };           # see §5b
  render            = { … }: …;
  restore           = { … }: …;
};
```

**Open question:** lifting per-pod hooks (`meta.backup.command = "pg_dump …"`). For Postgres-on-StackGres the engine already does it; for a random workload that needs a custom dump command, the package author *does* know the command. Probably promote `command` to a top-level `meta.backup` field with the constraint that it's only meaningful for filesystem engines that support hooks.

---

## 5d. Restoration tests as first-class

Doc 105 §A2 is blunt: "Untested backups are theatre." This RFC has to land restoration testing as a **scheduled, automated, observed** thing — not a runbook the operator runs once and forgets.

**Three layers, increasing cost / decreasing frequency:**

| Layer | What it proves | Cost | Cadence |
|---|---|---|---|
| **L1: Backup-readable** | Engine can list and decrypt the latest backup. No data restored. | Cheap (seconds). | Every backup run. |
| **L2: Sandbox restore** | Restore the latest backup into a *throwaway namespace / kind cluster*; engine reports success; smoke probe passes. | Medium (minutes). | Daily / weekly per receipt, per policy importance. |
| **L3: Application-validated restore** | After L2, the package's own probe runs against the restored instance: row counts within tolerance, schema version matches, app-defined `backupRestoreCheck` query returns sane data. | High (custom per package). | Weekly / monthly. |

**Where it lives in the contract:**

- L1 is part of `out.backupEngine.render` — every Schedule CR also includes a check phase (most engines support this natively: `restic check --read-data-subset`, k8up `Check` CRD, Velero schedule with `--validate`). Failure surfaces via the §5b alert path.
- L2 is a new verb — call it `kix rehearse-restore <workload> [--into kind|namespace]`. It's `kix restore` (doc 106 §1.2) with its target overridden to a sandbox and a hook to tear down on success. Reuses the kind-rehearsal cluster machinery from doc 106 §1.3.
- L3 needs a per-package hook — `out.backupRestoreCheck` on the package, a Job spec the verb runs after L2 completes. The package author is the only person who knows what "the data is intact" means for their workload; the contract gives them a place to express it without per-engine knowledge.

**Scheduled rehearsal:**
- A `cluster.backup.rehearsals = { critical = "weekly"; important = "monthly"; }` block. Rendered by the flavor as a `CronJob` (single-node era) or a controller in the activation operator (doc 62 era) that fires `kix rehearse-restore` against the configured importance class.
- Rehearsal results write to activation history (doc 106 §1.5) as a new `_type = "rehearsal"`, with verdict + timing.
- A scorecard rule `architecture.backupRehearsed` (already named in §4.4) checks the most recent rehearsal timestamp per receipt against the policy.

**Restore-time-budget feedback loop.** L2 measures actual bytes/sec restore throughput. The flavor stores it on the receipt; §5b's `RestoreTimeBudgetExceeded` alert reads it. The first time a backup grows past the RTO is the *one* thing operators always discover during the real incident — putting it in a generated alert is the whole reason this RFC exists.

**What we're explicitly *not* doing:**
- No "chaos engineering" — no random PVC-deletion-and-restore. Out of scope; lives in `interesting_thoughts/` if anywhere.
- No cross-cluster DR rehearsal in v1 (pull last week's S3 backup into a fresh cluster in a different region). Phase 4+ once Velero/CSI is in.

---

## 5e. Point-in-time restoration (PITR)

`kix restore --to <ts>` from doc 106 §1.2 only works if the engine actually *has* the bytes to land on `<ts>`. PITR is a **per-engine capability**, not a free property of "we take backups." This RFC has to make that capability visible at eval time so the compiler refuses incoherent requests and the operator knows the real RPO.

**Granularity reality per engine family:**

| Engine | Native granularity | How |
|---|---|---|
| CNPG / StackGres (Postgres) | Sub-second | Continuous WAL archive to S3 + scheduled base backup. `bootstrap.recovery.recoveryTarget.targetTime` does the replay. |
| etcd snapshots | Snapshot interval (typically 5–30 min) | Discrete snapshots; no replay between. |
| restic / k8up | Schedule interval (hourly/daily) | Each run is an independent snapshot; `restore --time <ts>` picks the closest preceding snapshot, no replay. |
| Velero (CSI) | Schedule interval | Same — discrete VolumeSnapshots. |
| MinIO / object versioning | Per-object operation timestamp | Object-level only; not workload-level. |

So `--to '2026-04-25T03:00Z'` against CNPG means "replay WAL up to that instant"; against k8up it means "give me the snapshot closest to and not after that instant"; against etcd it means the same with coarser granularity.

**Contract addition:**

```nix
out.backupEngine = {
  …
  pitr = {
    mode        = "continuous";    # | "discrete" | "none"
    granularity = "1s";            # informational; for "discrete", typically equals schedule
    requires    = [ "wal-archive" ]; # capabilities the destination must satisfy
  };
};
```

**Intent side.** A package that *wants* PITR (a Postgres holding orders) declares it:

```nix
out.meta.backup = {
  consistency = "app-aware:postgres";
  importance  = "critical";
  pitr        = { rpo = "5m"; };   # max acceptable data loss
};
```

The cluster-side wiring then has to pick an engine whose `pitr.mode = "continuous"` (or `"discrete"` with `granularity ≤ rpo`). A package asking for `rpo = "5m"` against a `discrete`-only engine on a daily schedule is a hard eval error — same scorecard machinery as `architecture.backupHasRestore`.

**Verb behaviour (extends doc 106 §1.2):**
- `kix restore <workload> --to <ts>` — engine-dispatched as before. For `continuous` engines, the verb plumbs `<ts>` into the recovery CR. For `discrete` engines, the verb resolves `<ts>` to the closest preceding snapshot at *plan time* and prints "restoring to nearest available point: `<actual-ts>` (Δ from request: 4h 12m)" so the operator can confirm before applying.
- `kix restore <workload>` (no `--to`) — restores the latest. Doesn't require any PITR capability.
- `kix restore <workload> --list-points [--since <ts>]` — engine reports available restore points (continuous: a `[start, end]` range; discrete: a list of timestamps). Reuses `out.backupEngine.listPoints`.

**New scorecard rule:**
- `architecture.pitrSatisfied` — every receipt with `meta.backup.pitr.rpo` set must resolve to an engine whose `pitr` capability satisfies it. Hard error.

**Receipt surface (for compliance / monitoring):**
- `out.backup.pitr = { mode; effectiveRpo; oldestRecoverablePoint; newestRecoverablePoint; }` — read by the §5b alert pack to fire `PITRWindowDegraded` when WAL archiving lags or snapshots stop landing.

**Open questions:**
- **Multi-engine PITR coherence.** If a workload has both CNPG-native (continuous) and Velero (discrete daily) receipts, `kix restore --to <ts>` should default to the engine with the finer granularity but allow `--via cnpg` / `--via velero` override. Open Q2 (multi-engine-per-resource) gets sharper here.
- **WAL retention vs. backup retention.** Continuous engines have *two* retention knobs (base backup retention, WAL retention) that together define `oldestRecoverablePoint`. Policy schema in §4.2 needs `policies.<…>.pitr.walRetention` separately from `retention.daily/weekly/monthly`. Confirm shape when CNPG goes in (Phase 1).
- **Application-level PITR vs. PVC-level PITR.** A single Postgres at `t-5m` is well-defined. A *cluster* of services restored to `t-5m` collectively (cross-workload consistent point) is not — different engines, different clocks, no global commit. Out of scope for v1; document the limitation. Probably never solvable in the general case without app-level cooperation; doc 67 (stateful migration orchestration) is the right home if it ever is.

---

## 6. Alternatives considered

**A. `meta.backup = true` as a boolean.** Insufficient — the cluster has no way to choose an engine without knowing whether the data is filesystem-safe vs. needs operator-native handling. Pushed back to the author with a small enum (`consistency`).

**B. Backup as a passthrough instance (doc 65).** The cluster declares `instances.backup = { … }`, packages depend on it via DI, the same way they depend on storage classes. *Tempting* and structurally clean, but:
- A passthrough instance per *engine* leaks into every dependent's eval. With three engines per cluster you fan out a lot of phantom deps.
- The "render N PVC-level Schedules from the matrix of intents" step is a flavor-side cross-cutting render, not a per-instance lookup. Capability + flavor matches that shape better.

We may still use a passthrough instance for the *destination* (the S3 bucket / restic repo), since that's a true external reference (doc 65's archetype). The engine itself is a flavor concern.

**C. Per-package config block (today's StackGres pattern).** Each package grows a `backup = { schedule, repo, ... }` block. Rejected: violates the layering doc `63a` set for storage. Cluster operator concerns must not live in package code.

**D. Adopt Velero only, lean on CSI snapshots.** Doesn't work on `local-path` (k3s default), doesn't beat operator-native consistency for Postgres, and doc 105 §A2 explicitly rejects the "snapshot the PVC and pray" approach for stateful workloads. Velero stays *one* engine in the matrix, not the matrix.

**E. Defer to backup operators entirely (no kix contract).** "Just install Velero / k8up via Helm, write CRs by hand." Rejected: the whole point of doc 90 §L2 is that backup-as-runbook is not production. Without a kix contract, the compiler can't refuse `ludo-prod` and `kix restore` has nothing to dispatch on.

---

## 7. Open questions

1. **Consistency enum granularity.** `"app-aware:postgres"` vs. a richer schema like `{ family = "postgres"; flavor = "stackgres" | "cnpg"; }`. The latter is what `kix restore` needs at dispatch time. Probably both — the *intent* is `app-aware:postgres`, the *receipt* in `out.backup` is the richer record.

2. **Multi-engine-per-cluster expression.** The §4.2 sketch maps `consistency → engine` 1:1. What about wanting *both* CNPG-native backups *and* a Velero CSI snapshot of the PG PVC for DR? Two valid receipts on one resource. Probably allowed; needs a `cluster.backup.policies.<…>.engines = [ "primary"; "dr-csi" ]` shape.

3. **Cross-namespace destination references.** Restic password lives in a SOPS-hydrated Secret somewhere. How does the engine in namespace A reference a Secret the operator put in namespace `kix-system`? Touches doc `archive/78_cross_namespace_secret_refs.md`.

4. **Quiesce coordination on restore.** Doc 106 §1.2 explicitly defers this to doc 67. Confirm: this RFC stops at "engine emits restore activation"; doc 67 owns "pause dependents while the engine runs."

5. **Where do backup destinations live in the DSL?** Doc 105 §B1 line 278 already asks this. §4.2 above says `cluster.backup.destinations` (matches `63a`). Confirm shape with the first concrete `clusters/ludo/` migration.

6. **Schedule expression.** Cron string vs. structured (`{ daily = "02:00"; weekly = "sunday@03:00"; }`). DSL principle says don't invent new fields — but cron is famously read-only. Lean structured for `policies.*`, allow cron passthrough for engine-specific niceties.

7. **Receipt schema for compliance.** What exactly goes into `out.backup` so the compliance export (`archive/61`) can render evidence? At least: engine identity, destination identity, schedule, retention, last-success-timestamp source (which Prometheus metric / status field). Needs a pass once doc 102 monitoring auto-wiring lands so we know the read path.

8. **Rehearsal as a kix concept.** A backup is only real once you've restored it. Doc 105 §A2 says "untested backups are theatre." Should a `kix rehearse-restore <workload>` verb exist alongside `kix restore`? Probably yes, post-v1, ties into doc 106's verbs and to kind-rehearsal cluster machinery.

9. **Interaction with `meta.lifecycle = "stateful"`.** Today the lifecycle tag is a free-form marker. This RFC implicitly upgrades it to "stateful ⇒ must have `meta.backup` intent or be explicitly waived." Confirm waiver shape (`meta.backup.waived = "ephemeral cache, regenerable"`), and whether that's a free string or a small enum.

10. **`local-path` and snapshotless storage.** A clean `architecture.backupHasRestore` rule would refuse Velero+CSI on `local-path`. The matrix needs a pre-check that an engine's *required capabilities* (CSI snapshots, S3, …) are present in the cluster's storage flavor. Reuses the capability machinery from doc 100 §D2 / doc 96.

---

## 8. Phased implementation

**Phase 0 (this doc → ROADMAP).** Land the contract surface (`meta.backup` schema + `cluster.backup` flavor + `out.backupEngine` engine convention) without any engine implementation. The compiler can already enforce `architecture.statefulNeedsBackup` at warning level by inspecting intent presence.

**Phase 1 (homelab driver).** Implement two engines end-to-end: `k8up` (filesystem) and `stackgres`/`cnpg` (app-aware:postgres). Wire `clusters/ludo/` to use both. One end-to-end restore rehearsal in kind from a real ludo backup. This is doc 105 §B1's "Day-1" deliverable.

**Phase 2 (`kix restore`).** Land doc 106 §1.2 against the `out.backupEngine.restore` convention. Promote `architecture.statefulNeedsBackup` to error under `single-node` module (doc 106 §2.5).

**Phase 3 (Velero / CSI).** Add Velero as a third engine for the DR-snapshot story, gated on CSI snapshot capability. Multi-engine-per-resource policy (open Q2).

**Phase 4 (compliance + rehearsal + PITR).** Receipt schema for compliance export; `kix rehearse-restore` verb (§5d L2/L3); `architecture.backupRehearsed` rule; PITR contract (§5e) including `pitr.mode`, `architecture.pitrSatisfied`, `--list-points`, WAL-retention policy split. Auto-generated alert pack (§5b) goes live once doc 102 monitoring auto-wiring lands.
