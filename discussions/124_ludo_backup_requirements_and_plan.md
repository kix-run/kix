# 124: Ludo backups — requirements & rollout plan

**Status:** Draft — concrete plan, research-grounded (tool facts checked 2026-07-04)
**Related:** `105_ludo_homelab_operational_readiness.md` §A2 (this doc concretizes it), `108_backup_capability_contract.md` (the kix contract — §6 feeds its Phase 1), `112_backup_operationalization.md` (trust loop), `90_ludo_north_star_ideation.md` §L2.
**Supersedes:** none. 108/112 remain the kix design record; this is the ludo operational plan.

## Why this doc

Ludo v1 is deploying with **zero backups**. Immich holds Luca's photos — irreplaceable
data — on a single NVMe behind k3s `local-path`. Disk death today means total loss.
Docs 108/112 design the *kix contract* for backups; 105 §A2 sketched a plan but
asserted its tools. This doc thinks through the actual requirements for the ludo node,
evaluates the concrete tools against them, and lands a staged plan that is deployable
now and adoptable by the 108 contract later.

## Assumptions to confirm (asked, unanswered — plan proceeds on defaults)

1. **Hardware:** an external HDD (~1TB) is/can be attached as the local backup tier
   (105's assumption). `cluster.nix`'s header says "512GB SSD + 4x HDD raidz2" but the
   active nuc config is a 1TB Kingston NVMe on **ext4** (the ZFS disko layout is
   explicitly not imported) — the header looks stale. **Confirm what disks exist.**
2. **RPO for photos: 24h** (nightly). Phones retain recent shots, so a lost day is
   usually re-uploadable.
3. **Off-site tier: cheap cloud now** (Backblaze B2 at 200–500GB ≈ $2–3.5/mo),
   second-machine rest-server as a possible later upgrade.
4. **Pragmatic v1:** wire backups directly (node flake + ludo config), out-of-band of
   the future `meta.backup` contract. Data safety first; 108 adopts it later.

## 1. What's on the node — data inventory

| Class | Data | Where | Backup? |
|---|---|---|---|
| **A — irreplaceable** | Immich originals: `upload/`, `library/`, `profile/`, `backups/` (built-in DB dumps) inside the 100Gi PVC | local-path PVC, ns `immich` | Yes — nightly, off-site copy mandatory |
| **B — painful to lose** | Immich Postgres (albums, faces, metadata) | StackGres PVC, ns `data` | Yes — as *logical dump*, never as live file copy |
| **C — regenerable** | Immich `thumbs/`, `encoded-video/`; Valkey (cache + BullMQ queue); Prometheus/Grafana/Loki data; k3s state; all manifests (kix rebuilds from git) | various | No. Post-restore: re-run Immich jobs. Immich's own discussion confirms Valkey holds only re-runnable queue state. |
| **D — keys & out-of-band secrets** | age/SOPS private key, k3s token (agenix), restic repo password, out-of-band cluster Secrets (`telegram-bot` token, `ludo-valkey-v1` password) | node / heads | Off-node custody (password manager ×2 humans), **not** part of the restic story — the repo password especially must survive node death or every backup is unreadable |
| Future | Vaultwarden (SQLite + `rsa_key.pem` + `attachments/`), Home Assistant, NAS PVC | gated off today | §5 pre-wires the hooks |

Two structural notes:

- **The cluster itself needs no backup.** kix regenerates every manifest from git —
  the "verifiable cluster artifact" makes Velero-style cluster-resource backup
  redundant. Only *data* and *keys* need to survive. The exceptions are the few
  Secrets created out-of-band (`telegram-bot`, valkey password): keep their values in
  the password manager and list them in the rebuild runbook.
- **Immich ships the consistency answer.** Immich's built-in DB backup (stable, on by
  default) runs `pg_dump` nightly at 02:00, keeps 14 dumps in `backups/` *inside the
  upload PVC*. A file backup of the PVC taken after 02:00 therefore contains a
  matching DB dump + files pair — DB-first ordering, which is the recommended order
  (drift becomes orphaned files, not dangling DB rows). Verify it's enabled in the
  admin settings; it makes every snapshot self-consistent for free.

## 2. Failure scenarios → requirements

Ordered by likelihood:

| Scenario | Requirement |
|---|---|
| Fat-finger / app bug deletes data | Point-in-time history (restic snapshots + retention), local restore, fast |
| NVMe dies | Full copy on a *different disk* (external HDD repo) |
| Node dies entirely (PSU, fire, theft) | Off-site copy + keys off-node + documented rebuild path that works from a blank machine |
| Node compromised / ransomware | Off-site copy the node **cannot delete** (append-only / delete-less credentials) |
| Backups silently broken for months | Failure alert to Telegram + staleness alert + periodic restore rehearsal (doc 112's verify stage) |

Derived hard requirements: restore must be possible **without a running cluster**
(plain restic repo, readable from a laptop); repo password + age key live in ≥2
places that are not the node; Postgres backed up logically (live file copy of a
running PG data dir is corrupt by construction).

## 3. Tool decisions

Research summary (three parallel web-research passes, 2026-07-04; details in the
session, key facts inline):

### 3.1 Velero — disqualified on this node

Velero is healthy (CNCF Sandbox 2026, v1.18.x) but its file-system backup explicitly
**rejects `hostPath` PVs — which is exactly what k3s `local-path` creates**
(velero#5705, #8161). It also requires an object store (no plain-directory/rest-server
backend) and its restic uploader is deprecated (kopia-only forward). Our existing
`kix/packages/velero` stays for CSI-capable clusters (nw1-class); it cannot serve ludo
v1. This kills 108's implicit "Velero as the generic engine" assumption for the
homelab flavor.

### 3.2 Foundation: NixOS host-level restic on the k3s storage dir

`services.restic.backups` in the node flake, backing up
`/var/lib/rancher/k3s/storage/` (local-path lays PVCs out as
`pvc-<uid>_<namespace>_<name>` — self-describing, per-PVC restore mapping is trivial)
to a restic repo on the external HDD.

Why this beats the in-cluster operators for v1:

- **Simplest failure surface** — no CRDs, no operator, survives every
  Kubernetes-layer failure; it can restore data *before* the cluster exists (the only
  option with that property).
- **Declarative in git** — the node flake is already the NixOS config; backups become
  code the same way everything else on ludo is.
- **Best restore story** — plain restic repo: `restic mount` from a laptop.
- **Native off-site** — `restic copy` HDD→B2 without re-reading source data.
- K8up (CNCF Sandbox, v2.15.0 2026-03) is the best-fit *in-cluster* operator —
  snapshot-free by design, handles RWO placement, plain-restic repos, `local` + S3 +
  rest-server backends, decent metrics — and is the right **doc 108 Phase 1 engine**.
  But it adds an operator + per-namespace CRs without adding data safety on a single
  node. Adopt it when the contract lands, not before. VolSync (healthy, v0.16.0
  2026-06) works CSI-less via `copyMethod: Direct` but has no consistency hooks and
  per-PVC CR boilerplate — the alternative, not the pick. No credible new tool
  emerged 2025–2026.

Include/exclude (initial): include `pvc-*_immich_*`; exclude `pvc-*_data_*` (live PG
data dir — covered logically per §3.3), `pvc-*_monitoring-system_*`, valkey PVC if
one exists, and inside the immich PVC `thumbs/` + `encoded-video/` (regenerable).
Future namespaces (`nas`, `vaultwarden`, `homeassistant`) get included as their
features flip on. Prefer an explicit include-list so a new PVC is a conscious
decision (and a scorecard-shaped nudge later).

Schedule 03:30 nightly — after Immich's 02:00 DB dump, during quiet hours (originals
are write-once, so live-read risk is minimal). Retention: 7 daily / 4 weekly / 6
monthly, `restic forget --prune` weekly, `restic check` weekly +
`--read-data-subset=5%` monthly (112's store-stage integrity op).

### 3.3 Postgres: logical dumps now, StackGres-native later (maybe)

StackGres (healthy, 1.18.8, 1.19 imminent) native backups are WAL-G base backups +
WAL archiving with real PITR — but **object storage is mandatory** (`SGObjectStorage`
is s3/s3Compatible/gcs/azureBlob only; no filesystem backend). On this node that
means running an S3 gateway first — and MinIO is dead as OSS (archived 2026-02);
**Garage** is the current homelab pick.

Decision: **v1 does not enable StackGres native backups.** The only DB is Immich's,
its built-in nightly `pg_dump` already lands inside the backed-up PVC, and a 24h RPO
is accepted. Native backups would add: Garage on the same node, WAL-archiving
failure → `pg_wal` fills the shared disk → Postgres down (the classic single-node
gotcha), and an alerting obligation (`pg_stat_archiver`, SGBackup status) — real
operational surface for RPO we don't need yet. Revisit when (a) a second DB consumer
with tighter RPO appears, (b) remote S3 exists anyway, or (c) 108 Phase 1 wants the
app-aware engine exercised. When it happens: the `stackgres-cluster` package already
has the backup block (`enabled = false` today); DR restore from bucket-only works via
`replicateFrom.storage` or by re-applying exported SGBackup CR YAMLs — export those
alongside the bucket, StackGres never auto-discovers backups.

### 3.4 Off-site: Backblaze B2 with delete-less credentials

At 200–500GB, B2 metered (~$6.95/TB/mo → $2–3.5/mo) undercuts Hetzner's 1TB box
(€3.20+VAT); restic has a native backend. Ransomware posture: restic can't use B2
Object Lock directly (restic isn't lock-free), so use the standard pattern — an
application key **without `deleteFiles`** + bucket lifecycle rules retaining hidden
versions; prune runs from the laptop with a full key, never from the node.
Mechanics: `restic copy` from the HDD repo (init the B2 repo with
`--copy-chunker-params --from-repo` on day one or dedup breaks). A friend's
rest-server with `--append-only` remains the strongest (and free) upgrade later.

### 3.5 Deliberately skipped

Cluster-resource backup (kix owns it), Valkey (queue state, re-runnable), monitoring
data, ZFS reprovision of the node (orthogonal; the ext4→ZFS question stands alone),
Longhorn/CSI-snapshot paths (Phase-3-hardware territory, changes the whole calculus
when a second node arrives).

## 4. Rollout plan

**Stage 0 — key custody (before any backup exists; blocks everything).**
Generate the restic repo password; store it + the age private key + the out-of-band
secret values (telegram-bot token, valkey password) in ≥2 off-node places (Adam's and
Luca's password managers). A backup whose key lives only on the node is theatre.
Confirm the HDD (assumption 1).

**Stage 1 — local tier (day 1).**
Verify Immich's built-in DB backup is on (02:00, 14 kept). Add
`services.restic.backups.ludo` to `ludo/node/modules/` per §3.2 (03:30, includes/
excludes, retention, weekly check). systemd `OnFailure=` unit that curls the Telegram
bot — node-side, independent of the cluster's Alertmanager. Deploy, run once
manually, `restic snapshots` sanity check.

**Stage 2 — off-site tier (week 1).**
B2 bucket + delete-less app key + lifecycle rules; init repo with matched chunker
params; nightly `restic copy` after the local run; staleness signal — simplest v1:
a second `OnFailure` hook plus a weekly "latest snapshot age" check; proper
Prometheus metric (node_exporter textfile via post-hook, alert `> 36h`) as a
follow-up so it rides the existing Alertmanager→Telegram path.

**Stage 3 — prove restore (before calling any of this "done"; doc 112's point).**
One rehearsal, from the B2 repo, pretending the node is gone: restore the Immich PVC
subtree to a laptop, load the contained DB dump into a throwaway Postgres (or
ludo-kind), spot-check assets. Write the runbook (`ludo/node/docs/` or demo/)
including the out-of-band-secrets list. Repeat quarterly until 112's rehearsal
machinery automates it.

**Stage 4 — later, on demand.**
Vaultwarden: pre-backup `sqlite3 .backup` hook (or its built-in `/vaultwarden
backup`, v1.32.1+), never copy the live db; `rsa_key.pem` + `attachments/` are the
must-haves. Home Assistant: use its native scheduled encrypted tars (2025.1+) and
back those up; exclude the live recorder DB. StackGres native + Garage per §3.3.
K8up as the 108 Phase 1 filesystem engine.

## 5. Alerting & verification summary

Capture: `OnFailure` → Telegram (stage 1). Store: weekly `restic check`, monthly
read-data subset; repo-disk-usage alert once the textfile metric exists. Verify:
quarterly manual rehearsal (stage 3) until kix grows `kix rehearse-restore`.
Restore: runbook, rehearsed once before "production".

## 6. What this feeds back into doc 108

- **Engine matrix, homelab column:** filesystem → *host-level restic* now, K8up when
  the contract lands; app-aware:postgres → StackGres-native (needs an object-storage
  *destination capability* — Garage, not MinIO); Velero → CSI clusters only. 108's
  engine table should note the hostPath disqualification explicitly.
- **A node-level engine is a real engine class.** 108's taxonomy is in-cluster-only;
  ludo v1's best engine is NixOS systemd. Whether the contract can *represent* an
  engine kix doesn't render (receipt without resources) is a new open question for
  108.
- **Destination capability schema** (112 §store): B2-delete-less-key vs
  rest-server-append-only vs plain-HDD map cleanly onto the proposed
  `{ encryption, offsiteReplication, immutability, integrityCheck }` — this plan is
  the first concrete instance to validate that schema against.
- `architecture.backupOffsite` / `backupEncryption` scorecard rules: stage 2 is the
  manual version of exactly what they should later enforce.

## Open questions

1. The four assumptions up top — especially the hardware reality (§0).
2. Should the include-list live in kix-visible config (a `ludo/` module emitting
   nothing but documenting intent) so the future `meta.backup` contract can diff
   against reality? Lean yes, cheap.
3. When Vaultwarden flips on: is 24h RPO acceptable for passwords, or does it deserve
   a tighter schedule / its own repo?
4. Second local machine (Luca's laptop? Adam's box?) as rest-server `--append-only`
   target — worth doing instead of B2, or in addition, once it exists?
