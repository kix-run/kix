# 67 — Stateful Migration Orchestration

**Status:** RFC
**Related:** `63a_storage_as_cluster_concern.md` (storage design), `45_cluster_hardware_profile.md` (hardware profile), `43_activation_operator.md` (activation deploy loop), `38_resource_type_tags.md` (resource type safety), `29_compiler-design.md` (compiler design)

---

## 1. Problem

Kubernetes can reconcile *desired state* against *live state* — but only within the boundaries of what the API server understands. When infrastructure changes underneath (storage backend swap, node topology shift, network reconfiguration), K8s sees unrelated deletions and creations. It has no concept of "this PVC on local-path is becoming a PVC on zpool" — it sees one PVC disappear and another appear. The data in between is your problem.

Today this is handled by:
- **Operators** (e.g. Rook, Longhorn, OpenEBS) that manage storage lifecycle within their own domain
- **Runbooks** that humans follow during infrastructure changes
- **Hope** that someone remembers to copy the data before hitting apply

All three fail at the same point: they operate in isolation. The storage operator doesn't know your app is stateful. The runbook doesn't know the deploy pipeline. The human forgets step 4.

### What kix knows that nobody else does

kix evaluates the *entire cluster definition* — packages, dependencies, storage, hardware profile, everything — into a content-addressed closure. When the cluster definition changes, the closure diff isn't just "these YAML files changed." It's:

1. **What** changed — PVC `immich-library` went from `storageClass: local-path` to `storageClass: zpool-fast`
2. **Why** it changed — the cluster hardware profile changed from `storageProvisioner: local-path` to `storageProvisioner: zfs`, and immich's storage config references the cluster default
3. **What depends on it** — immich's Deployment mounts this PVC at `/usr/src/app/upload`, the StatefulSet for postgres has a separate PVC that *didn't* change
4. **Whether it's stateful** — `meta.lifecycle = "stateful"` on the PVC package, consumer-side validation that this is user data (not a cache)

No GitOps tool, no operator, no runbook has all four pieces of information at once. ArgoCD sees (1) at best. Rook sees (1) within its own storage domain. A runbook captures (3) and (4) but is stale the moment someone changes the cluster definition.

### The ludo progression

The ludo cluster will iterate through many infrastructure states:

```
Phase 1: Single node, local-path storage, no ingress, no TLS
Phase 2: Single node, ZFS zpool on external drive, basic ingress
Phase 3: Single node, zpool + backup to S3, cert-manager TLS
Phase 4: Two nodes, replicated storage (Longhorn/OpenEBS), HA ingress
Phase 5: Three nodes, dedicated storage node, monitoring stack
```

Each transition involves stateful migration. Phase 1→2 moves immich photos from local-path to zpool. Phase 2→4 moves from single-node zpool to replicated storage across nodes. Phase 4→5 potentially rebalances storage to a dedicated node.

Without migration orchestration, each phase transition is a manual procedure. With it, `kix deploy` understands the transition and offers to handle it.

---

## 2. Core Concept: Migration Pairs

When the activation closure diff produces a `removed` resource and an `added` resource that satisfy certain conditions, they form a **migration pair** — a semantic statement that data needs to move from A to B.

### Detection

A migration pair is detected when:

1. **Same logical identity** — same package instance, same dep slot (e.g. both are `storage` for `immich`)
2. **Both stateful** — `meta.lifecycle = "stateful"` on the package, or resource type tag `stateful` (doc 38)
3. **Compatible type** — both are PVCs, or both are the same kind of stateful resource
4. **Different backing** — content hash differs because the storage class, size, access mode, or other infrastructure property changed

The key: this isn't heuristic matching on YAML. The dependency graph *knows* that instance `immich` had a `storage` dep resolved to PVC-A in the old closure and PVC-B in the new closure. The migration pair is a structural fact, not a guess.

### What a migration pair carries

```
MigrationPair {
  source: Resource       -- the old PVC (local-path, 100Gi)
  target: Resource       -- the new PVC (zpool-fast, 200Gi)
  consumer: Instance     -- immich (the thing that mounts it)
  depSlot: "storage"     -- which dependency changed
  reason: "storageClass changed: local-path -> zpool-fast"
  dataPath: "/usr/src/app/upload"  -- mount path in the consumer
  riskLevel: high        -- stateful, user data, not a cache
}
```

The `reason` is derived from the diff between old and new resource content — not just "changed" but specifically which fields changed and why (traceable through the hardware profile → storage config → PVC chain).

---

## 3. What the Deploy Loop Does With Migration Pairs

The activation operator (doc 43) has a DIFF → PLAN → APPLY → PRUNE cycle. Migration pairs insert a new phase between PLAN and APPLY: **MIGRATE**.

### 3.1 Detection (during DIFF)

The closure diff already produces `added`, `removed`, `changed`, `unchanged` sets. Migration pair detection is a post-pass on `removed × added`:

```
for each removed resource R where R.meta.lifecycle == "stateful":
  for each added resource A in the same instance + dep slot:
    if compatible_type(R, A):
      emit MigrationPair(source=R, target=A, ...)
      remove R from `removed` set
      remove A from `added` set
      add pair to `migrations` set
```

Resources matched into migration pairs are no longer treated as independent additions/deletions. They are handled by the migration phase instead.

### 3.2 Plan (migration strategy selection)

Each migration pair gets a strategy based on its properties:

| Scenario | Strategy | Automated? |
|---|---|---|
| Same node, same provisioner, size increase only | **Resize** — patch the existing PVC | Yes (if provisioner supports expansion) |
| Same provisioner, different storage class | **Copy** — create target, rsync data, swap mounts | Semi (needs downtime window) |
| Different provisioner (local-path → zpool) | **Copy** — create target, copy data, swap | Semi |
| Different node (single → multi-node storage) | **Migrate** — replicated copy with potential live migration | Depends on provisioner |
| Incompatible (RWO → RWX or vice versa) | **Manual** — flag as requiring human intervention | No |

The strategy selection is rule-based, not AI magic. The rules are explicit and auditable:

```nix
# Hypothetical — strategy rules in the migration planner
migrationRules = [
  {
    match = pair: pair.source.storageClass == pair.target.storageClass
                  && pair.target.size >= pair.source.size;
    strategy = "resize";
    automated = true;
  }
  {
    match = pair: pair.source.node == pair.target.node;
    strategy = "copy-local";
    automated = true;
    requiresDowntime = true;
  }
  {
    match = pair: true;  # fallback
    strategy = "copy-remote";
    automated = true;
    requiresDowntime = true;
  }
];
```

### 3.3 User confirmation

Before executing any migration, `kix deploy` presents the plan:

```
$ kix deploy .#cluster-ludo

Evaluating cluster-ludo...
  23 resources in 4 waves

Activation: ludo (generation 5)
  Previous: /nix/store/abc123...
  New:      /nix/store/def456...

  Closure diff:
    19 unchanged
     2 changed (immich Deployment, immich Service)

  Stateful migrations detected:
    immich/storage: local-path (100Gi) -> zpool-fast (200Gi)
      Strategy: copy-local (same node)
      Downtime: ~15 min (depends on data size)
      Data path: /usr/src/app/upload
      Risk: HIGH — user photos, not recoverable from source

  Options:
    [y] Execute migration (scale down immich, copy data, deploy new config)
    [s] Skip migration (deploy without data copy — PVC will be empty)
    [m] Manual (pause here, let me copy data myself, then continue)
    [a] Abort

  Choice:
```

This is the critical UX moment. The user sees *exactly* what's happening, *why*, and what the consequences are. No other tool can present this because no other tool has the semantic context.

### 3.4 Execution (the MIGRATE phase)

For a `copy-local` strategy:

```
1. Scale down consumer (immich Deployment replicas → 0)
2. Wait for pods to terminate (PVC unmounted)
3. Create target PVC (zpool-fast, 200Gi)
4. Wait for target PVC to be Bound
5. Spawn a migration Job:
   - Mounts source PVC (read-only) and target PVC (read-write)
   - Runs rsync/cp from source mount to target mount
   - Reports progress via Job logs
6. Wait for migration Job to complete
7. Continue with normal APPLY phase (immich Deployment now references new PVC)
8. Wait for immich to be healthy
9. (Optional) Delete source PVC after confirmation period
```

Steps 1-6 happen in the MIGRATE phase. Steps 7-8 are the normal APPLY phase. Step 9 is deferred — the old PVC is kept as a safety net until the user explicitly confirms the migration succeeded (or a configurable retention period expires).

### 3.5 The migration Job

The migration Job is a first-class kix resource, generated at deploy time (not eval time). It's not part of the closure — it's an ephemeral operational resource:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kix-migrate-immich-storage-gen5
  namespace: immich
  labels:
    kix.dev/migration: "true"
    kix.dev/source-pvc: immich-storage-old
    kix.dev/target-pvc: immich-storage-new
    kix.dev/consumer: immich
spec:
  template:
    spec:
      containers:
      - name: migrate
        image: alpine:3.19
        command: ["rsync", "-avP", "/source/", "/target/"]
        volumeMounts:
        - name: source
          mountPath: /source
          readOnly: true
        - name: target
          mountPath: /target
      volumes:
      - name: source
        persistentVolumeClaim:
          claimName: immich-storage-old
      - name: target
        persistentVolumeClaim:
          claimName: immich-storage-new
      restartPolicy: Never
  backoffLimit: 2
```

The Job image and copy command are configurable per migration strategy. Packages can declare custom migration logic:

```nix
# packages/immich — custom migration hint
meta.migration = {
  storage = {
    preCopy = "immich-cli export --path /source/export";
    postCopy = "immich-cli import --path /target/export";
    # or just: use the default rsync
  };
};
```

This is opt-in. Most packages need no custom logic — rsync is correct for filesystem-level storage. But databases (postgres), search indices (elasticsearch), and other structured storage may need application-level export/import instead of filesystem copy.

---

## 4. Beyond Storage: Other Stateful Migrations

Storage is the most common case, but the migration pair concept applies to any stateful infrastructure change.

### 4.1 Database migrations (version upgrades)

When postgres goes from 15 to 16, the package version changes but the data needs `pg_upgrade`. This is a migration pair where:

```
MigrationPair {
  source: stackgres-cluster (postgres 15)
  target: stackgres-cluster (postgres 16)
  consumer: immich
  reason: "postgres major version: 15 -> 16"
  strategy: "pg_upgrade" or "pg_dump/pg_restore"
  riskLevel: critical
}
```

The package can declare this:

```nix
# packages/stackgres-cluster
meta.migration = {
  majorVersion = {
    strategy = "operator-managed";  # StackGres handles pg_upgrade
    requiresDowntime = true;
    rollbackSafe = false;  # pg_upgrade is one-way
    maxVersionJump = 1;    # postgres can only upgrade one major version at a time
    hint = "StackGres operator will handle the upgrade. Ensure backup exists.";
  };
};
```

The `maxVersionJump` constraint is critical for packages like postgres where 15→17 is not a valid migration — you must go 15→16→17. kix can detect this at diff time: if the version delta exceeds `maxVersionJump`, it should error with a clear message ("postgres requires sequential major version upgrades — go from 15 to 16 first") rather than attempting a doomed migration. This is a compile-time safety check that no operator provides today.

kix doesn't reinvent pg_upgrade — it *knows* that the version change happened, warns the user, and can verify prerequisites (backup exists, operator is ready) before proceeding.

### 4.2 Node migrations (topology changes)

When the cluster goes from single-node to multi-node:

```
Phase: cluster.capabilities.multiNode: false -> true
       cluster.nodes: { ludo = {...}; } -> { ludo = {...}; ludo-2 = {...}; }
```

This triggers cascading changes:
- Deployments gain anti-affinity rules (if packages check `multiNode`)
- StatefulSets may need data rebalancing
- Services may gain topology spread constraints

kix can detect that the *reason* for the Deployment changes is the node topology change, not a code change. This affects the deploy strategy:

```
Topology change: single-node -> multi-node
  Affected packages:
    immich: Deployment gains anti-affinity (safe, rolling update)
    postgres: StatefulSet unchanged (single replica stays on original node)
    monitoring: DaemonSet gains new node target (additive, safe)

  No stateful migration needed — existing data stays on original node.
  New node will receive new pod replicas only.
```

vs. the case where the single node is *replaced*:

```
Topology change: node "ludo" removed, node "ludo-v2" added
  Affected packages:
    ALL — node replacement requires full data migration

  Stateful migrations:
    immich/storage: node ludo -> node ludo-v2 (copy required)
    postgres/data: node ludo -> node ludo-v2 (backup + restore required)

  This is a catastrophic migration. Consider:
    [1] Add ludo-v2 first, migrate, then remove ludo (recommended)
    [2] Direct migration with downtime
```

### 4.3 Ingress/TLS changes

Moving from no-ingress to ingress, or from self-signed to Let's Encrypt:

```
Phase: no ingress -> ingress-nginx + cert-manager
  New resources: Ingress, Certificate, ClusterIssuer
  Migration: none (additive)
  But: DNS must point to the new ingress IP before certs will validate.
  Warning: cert-manager will attempt ACME challenge immediately.
           Ensure DNS is configured before deploying.
```

This isn't a data migration — it's a *prerequisite check*. kix can detect that cert-manager was added and that it requires DNS resolution to work, and warn about the ordering dependency that exists *outside* the cluster.

### 4.4 Secret rotation

When a secret backend changes (e.g. inline secrets → external-secrets-operator → agenix):

```
MigrationPair {
  source: Secret (inline, managed by kix)
  target: ExternalSecret (managed by ESO, resolves to Secret)
  consumer: immich
  reason: "secret management changed: inline -> external-secrets"
  strategy: verify-equivalence
  riskLevel: medium — secret value must be identical
}
```

kix can't copy the secret (it may not have access to the external store), but it *can* verify that the new ExternalSecret resolves to a Secret with the same keys as the old inline Secret, and warn if keys are missing.

---

## 5. The Operator Replacement Thesis

Many Kubernetes operators exist primarily to manage lifecycle transitions that the API server can't express. If kix handles migration orchestration at the deployment layer, some of these operators become unnecessary.

### What operators actually do

| Operator | Core value | Migration-relevant? | kix replacement potential |
|---|---|---|---|
| **Rook/Ceph** | Storage provisioning + pool management + data migration | Yes — pool rebalancing, OSD migration | Partial: kix can orchestrate PVC migrations, but Rook's real-time rebalancing requires in-cluster intelligence |
| **Longhorn** | Replicated storage + volume migration + backup | Yes — replica rebuilding, volume migration between nodes | Partial: same as Rook |
| **StackGres** | Postgres lifecycle + minor/major upgrades + backup | Yes — pg_upgrade orchestration | High: kix can trigger pg_upgrade with proper sequencing, StackGres' day-2 value is mostly lifecycle |
| **Strimzi** (Kafka) | Broker lifecycle + partition rebalancing + version upgrades | Yes — rolling broker upgrades, partition reassignment | Medium: broker upgrades are sequenced, partition rebalancing is runtime |
| **cert-manager** | Certificate lifecycle + renewal | Partially — cert rotation is runtime | Low: cert-manager's renewal loop must run continuously |
| **Prometheus Operator** | Config reload + StatefulSet management | No — mostly config management | Low: but kix already generates the config |
| **ArgoCD/Flux** | Desired state reconciliation | Yes — this IS the deploy loop | Full: the activation operator replaces this entirely |

The pattern: **operators that primarily manage lifecycle transitions are partially or fully replaceable.** Operators that manage real-time runtime concerns (cert renewal, autoscaling, health-based failover) are not — those need continuous in-cluster intelligence.

### The "thin operator" complement

kix's activation operator (doc 43) already handles deploy-time orchestration. Migration orchestration extends this to handle the transitions that currently require fat operators. The combination:

- **kix deploy** handles: initial deployment, upgrades, config changes, infrastructure migrations
- **kix operator** handles: drift detection, reconciliation, crash recovery
- **Thin domain operators** handle: runtime concerns (cert renewal, autoscaling, real-time rebalancing)

The "thin operator" is stripped of lifecycle management (kix does that) and focuses only on runtime intelligence. A thin storage operator manages replication health and node failure recovery, but doesn't handle volume migration — kix does that during planned infrastructure changes.

---

## 6. Information Model: What kix Needs to Know

For migration orchestration to work, the system needs structured information at three levels.

### 6.1 Package-level: `meta.migration`

Packages declare how their stateful resources should be migrated:

```nix
meta.migration = {
  # Per dep-slot migration hints
  storage = {
    strategy = "rsync";           # rsync | pg_dump | operator-managed | manual
    requiresDowntime = true;      # must scale down consumer first?
    rollbackSafe = true;          # can we revert to source if migration fails?
    estimateDuration = size: "${toString (size / 100)}m";  # rough estimate from data size
    preCopy = null;               # command to run before copy (e.g. app-level export)
    postCopy = null;              # command to run after copy (e.g. app-level import)
    verifyCommand = null;         # command to verify migration succeeded
  };

  # Version-based migration hints
  majorVersion = {
    strategy = "operator-managed";
    rollbackSafe = false;
    hint = "Major version upgrades are managed by the StackGres operator.";
  };
};
```

Most packages won't declare this — the default (`rsync` for storage, `warn` for unknown changes) is correct for 80% of cases.

### 6.2 Cluster-level: hardware profile capabilities

The hardware profile (doc 45) already describes what storage backends exist. Migration orchestration adds:

```nix
cluster.capabilities.volumeExpansion = true;    # can PVCs be resized in-place?
cluster.capabilities.volumeCloning = true;      # can PVCs be cloned (CSI clone)?
cluster.capabilities.volumeSnapshots = true;    # can we snapshot before migration?
```

These influence strategy selection:
- If `volumeExpansion` and same storage class → prefer resize over copy
- If `volumeSnapshots` → take snapshot before migration (safety net)
- If `volumeCloning` → use CSI clone instead of rsync (faster, no downtime)

### 6.3 Instance-level: migration policy

The cluster operator can set migration policy per instance:

```nix
instances.immich.immich = {
  package = packages.immich;
  storage = "200Gi";
  migration = {
    auto = false;           # don't auto-migrate, always ask
    retainSource = "7d";    # keep old PVC for 7 days after migration
    snapshotBefore = true;  # take VolumeSnapshot before migration
  };
};
```

Or cluster-wide defaults:

```nix
cluster.migration = {
  defaultPolicy = "prompt";     # prompt | auto | disabled
  retainSource = "72h";         # default retention for old resources
  snapshotBefore = true;        # default: snapshot if capable
  parallelMigrations = 1;       # how many migrations to run concurrently
};
```

---

## 7. The Deploy UX: A Full Scenario

Ludo starts at Phase 1 (local-path) and the operator changes the cluster definition to Phase 2 (zpool):

```nix
# clusters/ludo.nix — Phase 1
modules = [
  kix.flavors.k3s
  kix.flavors.topology.single-node
  kix.flavors.storage.local-path
  # ...
];

# clusters/ludo.nix — Phase 2
modules = [
  kix.flavors.k3s
  kix.flavors.topology.single-node
  kix.flavors.storage.zfs        # changed
  {
    cluster.nodes.ludo.disks = [
      { device = "/dev/sda"; type = "ssd"; size = "512Gi"; role = "system"; }
      { device = "/dev/sdb"; type = "hdd"; size = "4Ti"; role = "storage"; pool = "tank"; }
    ];
  }
  # ...
];
```

The deploy:

```
$ kix deploy .#cluster-ludo

Evaluating cluster-ludo...
  28 resources in 5 waves

Activation: ludo (generation 5)
  Hardware profile changed:
    storage: local-path -> zfs
    node ludo: +1 disk (/dev/sdb, 4Ti, storage pool "tank")

  Closure diff:
    22 unchanged
     2 changed (StorageClass, zfs-provisioner DaemonSet)
     4 migrations detected

  Stateful migrations:
    1. immich/storage (HIGH risk)
       local-path 100Gi (/var/lib/rancher/k3s/storage) -> zfs-tank 200Gi (/tank/k8s)
       Strategy: copy-local (rsync, ~45 min for 78Gi used)
       Downtime: immich will be unavailable during copy
       Mount: /usr/src/app/upload (user photos)

    2. vaultwarden/storage (HIGH risk)
       local-path 1Gi -> zfs-tank 1Gi
       Strategy: copy-local (rsync, ~1 min)
       Downtime: vaultwarden unavailable during copy

    3. postgres/data (CRITICAL risk)
       local-path 10Gi -> zfs-tank 20Gi
       Strategy: pg_dump + pg_restore (recommended by package)
       Downtime: postgres + all consumers unavailable
       Note: package recommends backup verification before proceeding

    4. prometheus/data (LOW risk)
       local-path 50Gi -> zfs-tank 50Gi
       Strategy: skip (monitoring data is expendable)
       Recommendation: start fresh — historical metrics not worth migration cost

  Pre-migration checks:
    [OK] zfs pool "tank" exists on node ludo
    [OK] 4Ti available, 271Gi requested
    [OK] VolumeSnapshot capability: available (zfs snapshots)
    [WARN] No recent backup of postgres data found

  Options:
    [1] Execute all migrations in sequence (estimated 50 min)
    [2] Select individual migrations
    [3] Skip all migrations (deploy with empty PVCs)
    [4] Abort

  Choice: 2

  Select migrations to execute:
    [x] 1. immich/storage (copy)
    [x] 2. vaultwarden/storage (copy)
    [x] 3. postgres/data (pg_dump + pg_restore)
    [ ] 4. prometheus/data (skip — start fresh)

  Proceed? [y/n]: y

  Pre-migration snapshots:
    Snapshotting immich-storage... done (snap-immich-gen5)
    Snapshotting vaultwarden-storage... done (snap-vault-gen5)
    Snapshotting postgres-data... done (snap-pg-gen5)

  Migration 1/3: immich/storage
    Scaling down immich... 0/0 replicas
    Creating target PVC (zfs-tank, 200Gi)... Bound
    Starting migration job kix-migrate-immich-storage-gen5...
    [rsync] sending incremental file list
    [rsync] 78.3Gi / 78.3Gi (100%) — 43:12 elapsed
    Migration complete. Verifying...
    Target PVC: 78.3Gi used / 200Gi capacity [OK]

  Migration 2/3: vaultwarden/storage
    Scaling down vaultwarden... 0/0 replicas
    Creating target PVC... Bound
    Starting migration job... 0:47 elapsed
    Migration complete. [OK]

  Migration 3/3: postgres/data
    Scaling down postgres consumers (immich, n8n)... 0/0 replicas
    Running pg_dump on source... 2.1Gi dump created
    Creating target PVC... Bound
    Starting postgres with target PVC...
    Running pg_restore... 3:24 elapsed
    Verifying: table count matches [OK], row count spot check [OK]

  Applying remaining changes:
    Wave 0-2: skipped (unchanged)
    Wave 3: StorageClass, zfs-provisioner  [OK]
    Wave 4: immich Deployment, vaultwarden Deployment, postgres StatefulSet  [OK]
    Wave 5: Ingress (unchanged, skipped)

  Post-migration:
    immich: healthy (3/3 pods ready)
    vaultwarden: healthy (1/1 pods ready)
    postgres: healthy (1/1 pods ready)
    prometheus: healthy (1/1 pods ready, empty data — fresh start)

  Source PVCs retained for 7 days:
    immich-storage-old (local-path, 100Gi) — expires 2026-04-09
    vaultwarden-storage-old (local-path, 1Gi) — expires 2026-04-09
    postgres-data-old (local-path, 10Gi) — expires 2026-04-09

  Activation ludo@gen5 -> Healthy
  Run `kix migrate finalize ludo` to delete source PVCs early.
  Run `kix migrate rollback ludo` to revert to source PVCs.
```

---

## 8. What This Replaces and What It Doesn't

### Replaces

- **Manual runbooks for infrastructure changes.** The semantic diff IS the runbook — generated from the actual cluster definition change, not maintained separately.
- **Operator-driven volume migration.** For planned infrastructure changes (not failure recovery), kix handles the sequencing. The operator's migration logic is only needed for unplanned events.
- **Custom migration scripts per app.** The default (rsync) works for most apps. Custom logic is declared in `meta.migration`, not in a separate script repo.
- **"I forgot to copy the data" incidents.** kix won't let you deploy a stateful change without acknowledging the migration. The `skip` option exists but is explicit — you can't accidentally lose data.

### Does NOT replace

- **Runtime failure recovery.** If a node dies, kix isn't running — the storage operator handles replica failover. Migration orchestration is for planned changes only.
- **Continuous replication.** Longhorn/Rook replicate data in real-time for HA. kix does point-in-time copy during transitions.
- **Application-level migration logic.** kix can trigger `pg_upgrade` but doesn't implement it. It orchestrates the sequencing, not the data transformation.
- **Provisioning.** kix doesn't create the zpool or attach the disk. It knows the zpool exists (from the hardware profile) and uses it.

---

## 9. Implementation Approach

### Phase 1: Migration pair detection (eval-time)

Extend the closure diff to detect migration pairs. This is purely informational — `kix diff` shows them, `kix deploy` warns about them. No automation yet.

**Where:** `cli/kix/src/cluster/apply.rs` — extend `detect_changes()` to identify migration pairs from the `removed` and `added` sets using instance + dep-slot identity matching.

**Requires:** Package `meta.lifecycle` information accessible during diff. Currently available via `packageIndex.json`.

### Phase 2: Interactive migration prompts (CLI)

`kix deploy` presents migration pairs and asks the user what to do. Options: execute, skip, manual pause, abort. Still no automated execution — just awareness and decision capture.

**Where:** `cli/kix-cli/src/commands/deploy.rs` — add migration plan presentation between DIFF and APPLY phases.

### Phase 3: Migration Job generation and execution

The deploy loop can spawn migration Jobs (rsync-based) for simple storage migrations. Scale-down, copy, scale-up sequencing.

**Where:** New module `cli/kix/src/cluster/migrate.rs` — Job template generation, progress watching, verification.

**Requires:** `meta.migration` on packages (optional, defaults to rsync for storage).

### Phase 4: Strategy selection and pre-checks

Rule-based strategy selection (resize vs copy vs clone). Pre-migration snapshot support. Cluster capability checks (volumeExpansion, volumeSnapshots).

**Where:** Extends `migrate.rs`. Reads cluster capabilities from hardware profile.

### Phase 5: Source retention and finalization

Post-migration source PVC retention with configurable TTL. `kix migrate finalize` to clean up. `kix migrate rollback` to revert.

### Phase 6: Operator integration

The kix operator (doc 43) gains migration awareness. For `pruneStateful: prompt`, it can present migration plans and wait for approval (via Activation CR annotations or a separate MigrationPlan CR).

---

## 10. What You Might Be Missing

### 10.1 Multi-step migrations

Some transitions can't be done in one step. Moving from single-node local storage to multi-node replicated storage might require:

1. First add the new nodes and storage operator (additive, safe)
2. Then create replicated volumes on the new storage
3. Then copy data from local to replicated
4. Then switch workloads to new volumes
5. Then decommission local storage

kix could model this as a **migration plan** — a sequence of activations that must be applied in order, each with its own migration pairs. The user edits the cluster definition once (to the final state), and kix computes the intermediate steps.

This is ambitious but aligns with the "kix knows the whole picture" thesis. The intermediate states are derivable from the initial and final closures plus the cluster capabilities.

### 10.2 Dry-run migration cost estimation

Before committing to a migration, the user wants to know: how long will this take? How much downtime? How much temporary disk space?

kix can estimate this from:
- Source PVC used capacity (from live cluster query or last health check)
- Network bandwidth between nodes (from hardware profile or measured)
- Provisioner characteristics (zfs send/recv is faster than rsync)

This is the `estimateDuration` in `meta.migration` — rough but useful for planning.

### 10.3 Rollback complexity

Migration rollback is asymmetric. If the copy succeeded but the app fails on the new storage, rollback means:
1. Scale down the app
2. Point it back to the old PVC
3. Scale up

But if the app *wrote new data* to the new PVC before failing, that data exists only on the new PVC. True rollback would need bidirectional sync.

For simplicity, the rollback guarantee should be: **we can always revert to the state at migration start** (via snapshot). New data written after migration is the user's responsibility to reconcile.

### 10.4 Cross-namespace and cross-cluster migration

Moving a service from one namespace to another, or from one cluster to another, is also a migration pair — but across a wider boundary. The same semantic diff applies: kix knows that the immich *instance* moved from namespace `default` to namespace `immich`, and that its storage needs to follow.

Cross-cluster migration (ludo → nw1) is further out but follows the same model: the source and target are activations on different clusters, and the migration Job would need cross-cluster access (or an intermediate export/import step).

### 10.5 Operator coordination

When operators DO exist (e.g. StackGres for postgres), kix needs to coordinate with them, not fight them. The `strategy = "operator-managed"` hint means:

1. kix updates the CR (e.g. StackGres SGCluster version field)
2. kix waits for the operator to handle the migration
3. kix verifies the result (healthy pods, data integrity check)

kix becomes the orchestrator, the operator becomes the executor. This requires that the operator exposes status conditions that kix can watch.

### 10.6 Testing migrations

Migration strategies should be testable without touching production data. Possible approaches:
- `kix migrate --dry-run` — show the plan without executing
- `kix migrate --test` — create a temporary clone of the source PVC, run the migration on the clone, verify, delete the clone
- Migration integration tests in CI — spin up kind cluster, create source state, run migration, verify target state

### 10.7 The "known-unknown" problem

kix can detect migration pairs for changes it understands — storage, postgres versions, node topology. But some changes are opaque: a Helm chart upgrade that internally restructures its storage, or a CRD change that moves data between fields.

For opaque changes, kix should at minimum warn: "this stateful resource changed in ways I can't fully analyze — manual verification recommended." The type tag system (doc 38) helps here: resources tagged `stateful` that change content-hash always trigger a warning, even if no migration pair is detected.

---

## 11. Open Questions

### 11.1 Should migration pairs be first-class eval-time objects?

Currently proposed as deploy-time detection (CLI/operator). But if they were eval-time objects (produced by `buildCluster` when comparing against a baseline), they could be:
- Visible in `kix diff` output
- Validated by scorecard rules ("no unacknowledged stateful migrations")
- Persisted in the activation as metadata

This requires `buildCluster` to accept a "previous activation" as input — comparing two closures at eval time, not just at deploy time.

### 11.2 How does this interact with the activation operator's `pruneStateful` policy?

Doc 43 has `pruneStateful: prompt | auto | disabled`. Migration pairs should take precedence: if a stateful removal has a matching addition (migration pair), it's not a prune — it's a migration. The `pruneStateful` policy applies only to stateful resources that are truly being removed (no migration target).

### 11.3 What about StatefulSet-managed PVCs?

StatefulSets create PVCs via `volumeClaimTemplates`. These PVCs aren't in the kix closure — they're created by K8s at runtime. When a StatefulSet's volume claim template changes (different storage class), K8s doesn't migrate the existing PVCs. kix would need to detect the template change and handle the migration of K8s-managed PVCs.

This is a harder problem because the source PVCs aren't in the closure. kix would need to query the live cluster for PVCs matching the StatefulSet's naming pattern and include them in the migration plan.

### 11.4 Migration as a graph concern, not just pair-wise?

A storage backend change might affect 10 PVCs. Rather than 10 independent migration pairs, this could be modeled as a single **migration event** with a shared cause (storage backend change) and a coordinated execution plan (shared migration Job, parallel copies, single downtime window).

This is the "migration plan" concept from §10.1 — a higher-level orchestration unit. Worth designing but not required for Phase 1.

### 11.5 Declarative migrations: could the migration write back into code?

Speculative idea: when `kix deploy` detects a migration pair and the user confirms a strategy, could the tool *write the migration intent back into the cluster definition* as a declarative annotation?

```nix
# Auto-generated by `kix deploy` after user confirms migration strategy
instances.immich.immich = {
  package = packages.immich;
  storage = "200Gi";
  pendingMigration = {
    from = { storageClass = "local-path"; size = "100Gi"; };
    to = { storageClass = "zpool-fast"; size = "200Gi"; };
    strategy = "copy-local";
    approvedBy = "luca";
    approvedAt = "2026-04-02T14:30:00Z";
  };
};
```

This would make migrations reviewable in PRs ("I see a pending migration for immich storage — is the backup confirmed?"), auditable in git history, and reproducible. The operator would execute a `pendingMigration` block during deploy, then kix could remove it after successful completion (another write-back).

The question is whether this is overengineered. The interactive prompt during `kix deploy` already captures the decision — writing it into code adds a git-commit-as-approval-record workflow that might not be worth the complexity. On the other hand, for teams with CI-driven deploys (no interactive prompt), a declarative migration block might be the *only* way to express "yes, I know about this migration, proceed."

Worth exploring further once the basic migration pair detection exists. Could start minimal: just a `migration.acknowledged = true` flag that the user sets manually to suppress the interactive prompt in CI.
