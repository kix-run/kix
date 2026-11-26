# 112: Operationalizing backups — the trust loop

**Status:** RFC / Draft
**Relevance:** Active
**Related:** `108_backup_capability_contract.md` (the contract this rides on), `105_ludo_homelab_operational_readiness.md` §A2/§B1, `106_ops_lifecycle_verbs_and_capacity_check.md` §1.2/§1.3/§1.5, `67_stateful_migration_orchestration.md` (quiesce on restore), `111_operator_experience.md` (`kix status`), `110_alerts_as_graph_resources.md` (one of the surfaces, not the spine), `archive/61_compliance_exports.md`.
**Supersedes:** none — sibling to 108.

## Why this doc

Doc 108 is the **contract** (intent / flavor / engine / receipts). It is not the day-2 story.

Backups are not alerts. Alerts are read-only observations of state. **Backups are managed operations that produce artifacts you have to be able to trust** — and the only proof the artifact is good is having restored it. PRINCIPLES §16 (day-2 is where the value lives) and 105 §A2 (untested backups are theatre) point at the same thing: a backup system whose *only* day-2 surface is "did it run last night" is the surface that lets you discover the backup is broken during the incident.

So the spine of this doc is the **trust loop**:

```
   capture ──▶ store ──▶ verify ──▶ restore
      ▲                              │
      └──────────────────────────────┘
```

Each stage has its own *operations*, its own *failure modes*, its own *personas with distinct concerns*, and its own *kix surface*. The receipt from 108 is plumbing that connects them; it is not the design.

Doc 110's structural lesson still applies — three personas, no `meta.X` magic, ride standard mechanisms. But the persona/concern matrix is different from alerts because the operations are different.

## The four stages

### 1. Capture — "did the bytes get written, consistently?"

**What happens:** the engine runs on schedule, takes a consistency-correct snapshot of the data, ships it to the destination.

**What can go wrong (uniquely to capture):**
- Schedule didn't fire (CronJob disabled, controller crashed).
- Engine ran but consistency was wrong (file-level read of a live Postgres → corrupt).
- Engine ran but the workload was unreachable (PVC mounted RW elsewhere, pod evicted mid-run).
- Backup hook ran but produced no bytes (`pg_dump` succeeded with empty output because credentials rotated).

**Persona concerns:**

| Persona | Owns at capture | Knows that nobody else knows |
|---|---|---|
| App maintainer | The *consistency command* — `pg_dump`, `redis BGSAVE`, etcd snapshot. Whether the workload tolerates a live file read. | `meta.backup.command`, the consistency enum value. Crucially: **what "no bytes" means** for this app — empty `pg_dump` from a working DB is suspicious; empty restic from an empty cache PVC is fine. |
| Platform | The engine matrix per consistency class. Defaults for schedule cadence per importance. | Engine selection logic. Schedule-vs-importance defaults. |
| Operator (SRE) | The schedule (ad-hoc overrides), pre-maintenance triggers, `pauseDuringMaintenance` opt-in. | Operational windows specific to this cluster. |

**kix surface:**
- `meta.backup.command` is promoted to a top-level field (108 §5c open question, resolve here: yes, with the constraint that filesystem engines that don't support hooks emit a build-time diagnostic).
- Schedule lives in `cluster.backup.policies.<importance>.schedule`. **No schedule on the package side, ever.**
- A captured-bytes signal is mandatory on the engine: `out.backupEngine.captureMetric` returns the bytes-written-per-run query. Engines without it emit a structured diagnostic (PRINCIPLES §6) telling the operator "no capture-size signal — recommend external bucket alarm".

### 2. Store — "are the bytes still there, healthy, and somewhere safe?"

**What happens:** captured bytes accumulate in a destination (local restic repo, S3 bucket, whatever). Old data ages out per retention. Repo grows. Optionally replicates off-site.

**What can go wrong (uniquely to store):**
- Repo corruption (bit-rot on the HDD, partial write).
- Repo full (linear growth + no retention pruning).
- Encryption key rotated, old backups unreadable.
- "Off-site copy" never actually configured; everything on the same disk as the workload (the homelab failure mode).
- Object lock / immutability not actually set; ransomware deletes the backups.

**Persona concerns — this is where personas split hardest:**

| Persona | Owns at store | Critically does *not* care |
|---|---|---|
| App maintainer | Nothing. Truly nothing — store is downstream of consistency. | Where bytes live, what they cost, who has the key. |
| Platform | Default destination shape per profile (homelab → local restic; production → S3 + IAM). The capability schema (encryption, off-site, immutability) destinations advertise. | Per-cluster keys, per-cluster bucket names. |
| Operator (SRE) | Destinations, encryption keys, retention budgets, off-site replication targets, cost ceilings. | What apps put in the bytes. |
| Compliance officer (sub-persona of operator in regulated envs) | Provable encryption-at-rest, provable off-site, immutability windows, audit trail of who could decrypt. | Anything else. |

**kix surface:**
- Destinations are first-class with a **capability schema**, not free-form: `out.destination.{ encryption, offsiteReplication, immutability, integrityCheck }`. Enforcement comes from this schema, not from the engine.
- A scorecard rule `architecture.backupOffsite` (warning, lifts to error in `production` profile) checks that at least one destination per receipt has `offsiteReplication = true`. **The single most important homelab footgun** (105 §A2): backup-on-the-same-disk-as-the-data fails the scorecard.
- `architecture.backupEncryption` (error always) requires `encryption.kind != "none"` on every destination. Hard error; encryption is not opt-in.
- Repo health (integrity check) is a **store-stage operation**, not capture: rendered as a separate Schedule by the engine (`restic check --read-data-subset`, k8up `Check` CRD). Surfaces independently from capture freshness.

### 3. Verify — "would it actually restore?"

This is the stage that doesn't exist today and is the whole reason the doc is worth writing. PRINCIPLES §4: forbid at compile-time what runtime would otherwise have to detect — kix can't compile-check that bytes-on-disk-restore-into-a-working-app, but it can make the *exercise* a first-class scheduled operation rather than a runbook.

**Three layers of verification, increasing cost:**

| Layer | What it proves | Owns it | Cost |
|---|---|---|---|
| **L1 — readable** | Engine can list and decrypt the latest artifact. | Engine (built into the Schedule). | Seconds. |
| **L2 — restorable** | Restore the artifact into a sandbox (kind cluster or throwaway namespace); engine reports success. | `kix rehearse-restore` verb (doc 106 §1.3 kind-rehearsal machinery). | Minutes. |
| **L3 — application-valid** | After L2, the package's own probe runs against the restored instance: row counts within tolerance, schema version matches, `out.backupRestoreCheck` Job returns sane data. | App maintainer authors `out.backupRestoreCheck`; verb runs it. | Custom. |

**Persona concerns:**

| Persona | Owns at verify | Why only they can |
|---|---|---|
| App maintainer | `out.backupRestoreCheck` — the Job spec that says "the data is intact." For Postgres: a SELECT against a known table. For Immich: file count + a hash of a known asset. | They are the **only** persona who knows what "intact" means for this app. Platform/operator literally cannot author this. |
| Platform | The rehearsal machinery (kind-rehearsal cluster, sandbox namespace, the verb). Default rehearsal cadence per importance. | Cross-cutting infra; same for every package. |
| Operator | Rehearsal cadence overrides, what to do on rehearsal failure (page vs ticket vs ignore-once). Post-rehearsal cost tracking (kind clusters cost compute). | Operational policy. |

**kix surface:**
- `out.backupRestoreCheck` on the package — optional but **strongly recommended**: a scorecard rule `architecture.backupHasRestoreCheck` warns when a `critical`-importance receipt has no L3 check.
- `cluster.backup.rehearsals = { critical = "weekly"; important = "monthly"; ephemeral = "none"; }` — flavor renders this as a recurring activation (`CronJob` in single-node era; controller in operator era). Each run writes to activation history (doc 106 §1.5) as `_type = "rehearsal"` with verdict + measured restore throughput + L3 check outcome.
- `kix rehearse-restore <workload>` is a verb, not a hidden mechanism. Operator can fire it any time. Same code path as the scheduled cron.
- Receipt grows `out.backup.lastRehearsal = { ts, verdict, throughputBytesPerSec, l3Check }`. This *is* read by alerts (the only place this doc concedes alert-shaped wiring) — `RehearsalStale` and `RestoreTimeBudgetExceeded` rides 110, but they are downstream of the verify *operation*, not its purpose.

### 4. Restore — "pull the trigger, recover the workload"

**What happens:** something broke. Operator points at a workload + a point in time. The engine produces an activation closure (108 §4.3) that: quiesces dependents, lands the bytes, brings the workload back, smoke-tests it.

**What can go wrong (uniquely to restore):**
- Dependents not quiesced — workload comes back with stale state, app picks up where it left off, double-spends.
- Restore succeeds but app-level migration is needed (schema downgrade, secret rotation post-restore).
- PITR target unreachable (asked for `t-5m` but engine only has 6h-discrete snapshots — silent failure if not caught at plan time).
- Operator restored the wrong instance / wrong namespace.
- Restore took 4× the projected time, RTO blown.

**Persona concerns:**

| Persona | Owns at restore | Why |
|---|---|---|
| App maintainer | Post-restore migration hooks (rare; e.g. "after restoring this Postgres, run `migrate up`"). Dependency order if app has multiple stateful components (DB before queue before workers). | App-internal state contract. |
| Platform | The verb plumbing, dependent-quiesce coordination (rides doc 67 when it lands; hardcoded scaledown until then), kind-rehearsal sandbox machinery. | Cross-cutting. |
| Operator | The decision: when, what point, what blast radius. Trust: do they believe the rehearsal data well enough to fire? | This is *the* incident-time operation; nobody else can pull this trigger. |

**kix surface:**
- `kix restore <workload> [--to <ts>] [--list-points] [--dry-run]` — doc 106 §1.2's verb, made real here.
- `--dry-run` is mandatory before v1: emits the activation diff (per doc 111's plan surface) showing exactly what will be quiesced, restored, and brought back. Operator confirms.
- Discrete-engine `--to` resolution prints the actual landing point ("nearest preceding snapshot: `2026-04-25T02:00Z` (Δ requested: 4h 12m)") at plan time, not after.
- Restore writes to activation history (doc 106 §1.5) as `_type = "restore"` with target + point + outcome + L3 check verdict. **Every restore is rehearsed-by-construction**: the same L3 check that runs in rehearsal runs after restore, and a failing L3 produces a structured diagnostic asking the operator whether to roll forward or roll back.

## What this means for the receipt

108's receipt (`out.backup`) carries the resolved choices. This doc requires it to also carry the **stage state**, because each stage's day-2 surface reads a different slice:

```nix
out.backup = {
  # ... 108's resolved-choice fields (engine, destination, schedule, retention, pitr) ...

  # Per-stage references — each is a query/path, not a value (PRINCIPLES §12).
  stages = {
    capture = { lastRunMetric; lastBytesMetric; consistencyCommand; };
    store   = { destination; integrityCheckSchedule; offsiteReplica; };
    verify  = { rehearsalSchedule; lastRehearsal; restoreCheckJob; };
    restore = { engineRestoreClosure; quiesceOrder; };
  };
};
```

Each `stages.<x>` is read by **one set of consumers** (CLI verb / scorecard rule / structured diagnostic / optional alert). Keeps the schema honest about which stage owns which concern.

## Cross-cutting concerns

These don't fit cleanly inside one stage but matter operationally:

- **Secrets rotation.** Encryption keys rotate; old backups must remain readable until retention drops them. Multi-key destinations are out of scope for v1 (108 Q3); this doc just flags it as a known cliff and lets the operator opt into a `--rekey` migration verb later.
- **Cost.** Every byte stored, every kind-rehearsal cluster spun up costs something. The receipt's destination capability schema includes an optional `costEstimate` field; the compliance/cost export rolls it up. Out of scope for v1 implementation, in scope for the schema so we don't have to break it later.
- **Trust artifacts.** L3 check verdicts + rehearsal throughput are the operator's evidence that backups work. They live in activation history; the compliance export reads them. PRINCIPLES §17 — trust evidence is a build/runtime *output*, not a post-hoc audit.
- **Off-site.** The single most operationally important property in the homelab case (105 §A2). Promoted to a destination capability + a scorecard rule, not a runbook reminder.

## What this is *not*

- **Not a contract redesign.** 108 stands; this doc adds operational structure on top.
- **Not an alerting design.** 110 owns alerting. Auto-emitted backup alerts ride 110 as one observation surface among many — not the spine.
- **Not a chaos-engineering harness.** Random failure injection is out of scope; lives in `interesting_thoughts/` if anywhere.
- **Not a cross-workload-consistent-restore design.** Per-workload PITR only (108 §5e Q3).
- **Not a multi-tenant isolation design.** 108 §3 multi-tenant persona is acknowledged; this doc doesn't add per-tenant key isolation. Defer to when a multi-tenant cluster drives it (PRINCIPLES §14).

## Phased rollout

**Phase 1 — capture + store, scorecard-enforced.** 108 Phase 1 lands engines (k8up, stackgres/cnpg). Receipt carries `stages.capture` + `stages.store`. `architecture.backupEncryption` (error), `architecture.backupOffsite` (warning, error in `production`). `kix status` surfaces capture freshness per node (rides doc 111).

**Phase 2 — restore.** `kix restore` verb (doc 106 §1.2), `--dry-run` mandatory, `--to` resolution at plan time. Restore writes activation history. `architecture.backupHasRestore` at error.

**Phase 3 — verify (the new thing).** `out.backupRestoreCheck` author surface. `cluster.backup.rehearsals` flavor schedule. `kix rehearse-restore` verb. `architecture.backupRehearsed` rule. `architecture.backupHasRestoreCheck` rule. Rehearsal results land on the receipt.

**Phase 4 — PITR + compliance + cost.** 108 §5e PITR contract. Compliance export reads stage state + rehearsal verdicts. Destination cost-estimate field.

## Open questions

1. **L3 check shape.** Job + exit code? Job + structured verdict (JSON on stdout)? Lean structured — same machinery as doc 80 diagnostics. Confirm in Phase 3.
2. **Rehearsal sandbox cost.** Kind-rehearsal clusters per workload per cadence is potentially a lot of compute. Do we share one rehearsal cluster across receipts in a window, or spin a fresh one per receipt? Lean shared, but per-receipt is more isolation; revisit when Phase 3 scales past 5 stateful packages.
3. **Capture-bytes-zero anomaly detection.** App maintainer knows whether "0 bytes captured" is suspicious for their workload. Express as `meta.backup.expectNonEmpty = true` on the package? Probably yes; one-line author surface, big payoff.
4. **Off-site as a hard error in production.** §2 lists `backupOffsite` as warning lifting to error under `production`. But "off-site" is fuzzy — same datacenter different rack? Different region? Different cloud? Need a granularity on the destination capability schema; defer concrete shape until a real production cluster wires it.
5. **Restore as a migration pair (rides 111).** Doc 111's migration-pair concept fits restore exactly: pre-restore plan + post-restore verdict. Should `kix restore` be modeled as a migration pair rather than a freestanding verb? Lean yes; revisit after 111 lands.
6. **Pre-flight at every stage vs only at restore.** PRINCIPLES §6: every failure that *can* fail at compile-time *must*. We can compile-check encryption-on, off-site-on, engine-implements-restore. We cannot compile-check "bytes are non-corrupted." Where does the "compile-check what we can, runtime-detect what we can't" line land per stage? Document explicitly when each rule lands.
7. **Waived stateful workloads.** A `meta.backup.waived = "regenerable"` workload (108 Q9) — does it skip *all* four stages, or does it still need a "we deliberately don't back this up" receipt for compliance? Lean the latter — compliance asks "what's not backed up and why."
