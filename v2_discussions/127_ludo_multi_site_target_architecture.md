# 127: Ludo multi-site target architecture (5 households, one cluster)

**Status:** Draft, target architecture to strive for; staged rollout from today's single node.
**Related:** `124_ludo_backup_requirements_and_plan.md` (the single-node v1 plan; stage 0 here),
`125_backup_abstraction_levels_and_state_contract.md` (this cluster is its level model made
real), `105_ludo_homelab_operational_readiness.md`, `90_ludo_north_star_ideation.md`,
`108_backup_capability_contract.md` / `112_backup_operationalization.md` (contract + trust
loop), `63a_storage_as_cluster_concern.md`, `107_overlay_edge_exposure.md`.
**Supersedes:** none. 124 stays the ship-now plan; this is the horizon it grows into.

## 1. Scope, goals, decided inputs

Ludo grows from one NUC to a five-household homelab platform. Known use: Immich (photos,
irreplaceable), Vaultwarden (passwords, availability-critical), Home Assistant (one
household, hardware-bound), Postgres via StackGres, monitoring, future NAS/media.

Decisions recorded from the 2026-07-05 planning session (Adam):

1. **Vaultwarden availability:** failover-in-minutes is enough; even a full outage is
   tolerable. Bitwarden clients cache vaults offline, so reads survive any server outage;
   only sync, web vault, admin, and new-device login pause. No active-active HA required.
2. **Tenancy:** single operator (Adam). Data may live on any household's node; encrypt at
   rest (ZFS native encryption + encrypted restic repos) as baseline hygiene, no strict
   locality constraint.
3. **Network:** all five households have decent uplinks (>=30 Mbit up assumed). No CGNAT
   known. Tailscale mesh (already the pattern in `ludo/node/modules/cluster.nix`).
4. **Access model:** Tailscale app on each user device. Public HTTPS exposure is a future
   ambition (see §12), not part of this target.
5. **Cloud budget:** minimal Hetzner; one small VPS is in budget if it pulls real weight.
6. **Hardware:** NUCs, Raspberry Pis, old laptops available; HDDs can be bought and placed
   freely.
7. **Topology:** concentrate compute and storage at S1 (the Home Assistant household,
   where today's NUC already lives); the other households consume remotely over the
   tailnet. One additional storage site (S2) covers disaster recovery. Spreading storage
   across all five households was considered and rejected as overkill: the requirements
   demand two physical locations for durability plus one failover target, not five.

## 2. Research verdicts that bound the design (2026-07-05)

Three web-research passes (Ceph/Rook, OpenEBS/Mayastor, landscape); key facts, so future
sessions do not re-litigate:

| Technology | Verdict for cross-household use | Decisive fact |
|---|---|---|
| Ceph/Rook stretch | Rejected | Stretch mode ceiling is 10ms RTT between data sites; HDDs explicitly not recommended for any stretch role; community unanimous against Ceph-over-VPN. Rook itself healthy (CNCF Graduated, v1.20). |
| OpenEBS Mayastor | Rejected | Strictly synchronous, maintainers state single-datacenter design; 3-node minimum; 2GiB hugepages + 2 cores pinned at 100% even idle; one disk per pool. |
| Longhorn | Rejected for WAN | Sync-only; wontfix'd issue: replica rebuilds over Tailscale fail on >70GB volumes. Its own cross-site feature (DR volumes) is async via backup target. |
| LINSTOR/DRBD protocol A | Rejected for WAN | Async buffer is a 10MiB TCP send buffer; writes block when it fills; LINBIT's own WAN guidance is snapshot shipping. Viable per-site block layer later. |
| OpenEBS LocalPV-ZFS | **Adopted** | GA, active (v2.10, 2026-06); CSI snapshots are real ZFS snapshots; clones, resize, per-StorageClass ZFS properties; pools declared in NixOS/disko; no control plane to babysit. |
| VolSync | **Adopted** | v0.16 (2026-06); `copyMethod: Snapshot` takes a CSI snapshot then ships restic to S3; ReplicationDestination gives declarative restore/warm standby; the k8s-at-home standard. |
| Garage | **Adopted** | v2.3 (2026-04); designed for geo-distribution ("200ms or less, 50 Mbps or more"); zone-aware placement; rf=3 across >=3 zones keeps full read-write through any single-site loss. No object-lock (mitigation §8). |
| Velero | Alternative | v1.18, now CNCF; CSI data movement solid. Its extra (cluster-resource backup) is redundant under kix rebuild-from-git. |
| StackGres remote/multi-zone | **Adopted** | Patroni-managed streaming replication across zones inside one cluster; async streaming over 20-40ms WAN is the standard DB answer. |
| MinIO | Dead | OSS gutted 2025, repo archived 2026-04. |

The structural rule all of these converge on: **block storage stays site-local; everything
that crosses a household boundary is asynchronous** (object replication, DB streaming,
snapshot shipping). This is also how clouds work (EBS is AZ-local; cross-AZ is S3,
snapshots, DB replicas), and it is 125's lowering thesis: same state, capture level chosen
by cluster shape.

### 2b. RAID vs Ceph/Rook at this scale

They answer different questions. ZFS RAID answers "a disk died" (plus checksummed scrubs
against bit-rot, snapshots, native encryption, cheap incremental send). Ceph answers "a
node died and storage must stay up without interruption": it wants 3+ nodes per site,
roughly 4GB RAM per disk (OSD), 10GbE to perform, and 3x replication keeps ~33% of raw
capacity (raidz1 on 4 disks keeps 75%, mirrors 50%). Ceph replication is also not backup:
deletions replicate instantly and there is no history without adding snapshots anyway.
The stated requirement ("Immich/NAS down is fine, data loss is unacceptable") is exactly
what ZFS-plus-offsite-backup covers and Ceph over-serves. Ceph re-enters at stage 5 only
if S1 reaches 3+ storage nodes *and* hosts something that cannot tolerate a failover
pause.

## 3. Topology

Three zones with nodes: S1 (dense), S2 (DR), H (Hetzner). S3-S5 are consumer households
with no hardware; they reach services over the tailnet exactly like S1 residents do.
`topology.kubernetes.io/zone` on every node from day one.

| Site | Role | Hardware (ambitious target) |
|---|---|---|
| S1 (main AZ, the Home Assistant household; today's NUC is here) | Primary site: 2-3 nodes, most storage, all primary workloads | Existing NUC (NVMe) + a second NUC (32-64GB) and/or an old laptop (battery = free UPS, natural home for the critical tier); 2-4 HDDs; Zigbee/Z-Wave USB |
| S2 (one other household) | DR + failover site | NUC (16-32GB, NVMe) + 2 HDDs |
| S3-S5 | Consumers | none required; optional Pi/laptop agent later if a local need appears |
| H (Hetzner) | Control plane, external vantage | 1x small ARM VPS (CAX11-class, ~4 EUR/mo) |

The dense-S1 shape has a property the spread-out alternative lacks: nodes inside S1 talk
at LAN latency, so replicated block storage and ordinary in-site HA (the things §2 rules
out *across* households) become available *within* S1 once it has 2-3 nodes. Node
failures (common) are handled locally at LAN speed; site failure (rare) is handled by
S2. Adding more storage households later is a Garage layout change, not a redesign.

### 3b. Hardware: what to buy

Archetypes (decision 2026-07-05: minimize and stage purchases):

- **Storage node (the thing to buy, twice over time):** N150/N305-class NAS board or
  ODROID-H4+-style box with 4x 3.5" SATA bays + NVMe boot, 32GB RAM, Jonsbo-N-style
  case; ~250-450 EUR barebones. Classic NUCs are the wrong buy here (1x NVMe + 1x 2.5"
  max). The box has enough CPU to double as a compute node, so S2 needs no second
  machine.
- **Compute (already owned, buy nothing):** the existing NUC stays S1's general compute
  node; an old laptop joins S1 at stage 4 as the critical-tier node (battery = built-in
  UPS). Laptops are not storage nodes (one drive slot).
- **Raspberry Pi: no role.** USB-attached storage is the classic ZFS reliability trap,
  and with Tailscale on every user device there is no per-home edge-router job either.
- **H:** Hetzner CAX11-class ARM VPS (~4 EUR/mo).

| Stage | Buy | Approx. cost |
|---|---|---|
| 1 | Hetzner VPS only | 4 EUR/mo |
| 2 | S1 storage node: 4-bay box, 32GB, boot NVMe, 2x 16-20TB (mirror) | 700-900 EUR |
| 3 | S2: same box class, 2x 12-16TB (mirror) | 600-800 EUR |
| 4 | nothing (laptop is free); second S1 mirror pair when the pool passes ~70% | drives only |

A single-disk S2 start would save ~150 EUR, but a disk death there means re-syncing the
full repo over the WAN (weeks at 10TB scale); the mirror is the cheaper insurance.
Recertified enterprise drives (~30-40% below new) are acceptable in mirrors: every
class-1 byte exists in three places, so an early drive death costs a resilver, not
data. Running cost counts too: each storage box idles at ~15-25W with two spinning
HDDs, roughly 50-70 EUR/yr at 0.30 EUR/kWh; S2's pool can spin down between backup
windows.

## 4. Control plane

One k3s cluster spanning all zones. Recommendation: **k3s server on the Hetzner VPS,
every household node an agent.**

- Agents keep running their pods when the apiserver is unreachable (kubelet autonomy), so
  a Hetzner outage does not take workloads down; it only pauses rescheduling and deploys.
- Rescheduling is exactly the failover mechanism for the critical tier, and the VPS has
  the best uptime and reachability of any candidate, so the scheduler should live there.
- etcd across households (20-40ms RTT) is borderline per k3s guidance; not needed yet.
- Compound-failure honesty: VPS down *and* the Vaultwarden site down simultaneously means
  no automatic failover until one recovers. Accepted for now; the upgrade is 3 servers
  (H + S1 + S2, embedded etcd over tailnet with tuned election timeouts) as a later stage.
- Datastore snapshots ship to Garage on schedule; kix rebuild-from-git plus the L0
  runtime-accreted complement export (125 §2) makes control-plane loss a rebuild, not a
  disaster.

**What the VPS is for, and for how long.** Two jobs only: (a) the apiserver/scheduler
in an independent failure domain, which is what makes failover *automatic* when S1 is
down (a scheduler inside S1 dies with S1; a 2+1 etcd across S1/S2 loses quorum in the
same event); (b) external watchman + dead-man's switch, which alone a free uptime
service could do. No data, no user traffic, no storage. Consequently: it is needed from
the moment automatic failover is wanted (stage 3) and for as long as it is wanted; it
can be skipped entirely if manual site-loss recovery (rehearsed rebuild from git +
restore, hours of RTO) is acceptable; and its stage-5 exit is a small control-plane
node in a third household (the one role where a Pi + SSD is fine, since it holds no
data), though a datacenter VM is the better failure domain for ~50 EUR/yr.

## 5. Network fabric

- All nodes join the tailnet (existing `cluster.nix` pattern). Node IP = tailscale IP.
- Cilium stays the CNI; inter-node pod traffic rides the tailnet in tunnel mode. Known
  engineering item: MTU stacking (tailscale 1280 minus vxlan overhead, ~1230); validate
  on a 2-node testbed before S2 joins.
- Users run the Tailscale app per device (decision §1.4). Services are reached by tailnet
  DNS names through the existing expose path (107). Failover routing is native: when a
  pod reschedules to another zone, the Service endpoints move with it; nothing external
  to Kubernetes is involved.
- Home Assistant note: established tailscale peers on the same LAN keep direct
  connections through an ISP outage, and the k3s agent keeps running pods through WAN
  loss, so home automation survives the house losing internet.

## 6. Storage

Two layers, both declarative:

**Per-node block (LocalPV-ZFS).** Each storage node has two zpools, declared in the node
flake via disko (the dormant `hosts/nuc/disko.nix` ZFS layout becomes real):

- `fast` (NVMe): hot PVCs; StorageClass `zfs-fast` (per-zone via allowed topologies).
- `bulk` (HDD mirror): Garage data, media/NAS volumes; StorageClass `zfs-bulk`.
- ZFS native encryption on both; keys via the existing agenix/SOPS flow.
- This replaces k3s local-path entirely and upgrades every PVC to crash-consistent CSI
  snapshots (the L3 level that 124's single node lacked).

**Cross-site object (Garage).** One Garage deployment, data on `zfs-bulk`, one node at
S1 and one at S2, **replication factor 2**, zone-aware: every object has one copy per
site, which together with the S1 primary gives class-1 data its classic 3-2-1. This is
the minimize-budget revision of an earlier rf=3 (2+1) plan: rf=3 would store every
backed-up byte twice at S1 for the sole benefit of S1-side write continuity while S2 is
offline. The rf=2 trade: Garage writes pause while either site is down (reads and
restores keep working from one copy). Backup jobs simply retry; the one continuous
writer is StackGres WAL archiving, so alert on archiving lag and keep pg_wal headroom
(the 124 gotcha, now with a bounded cause). Upgrade path if the pauses annoy: two more
S1 disks and a re-layout to rf=3 (2+1). Buckets: `volsync-*` restic repos, `stackgres-*` (WAL + base
backups), `cluster-l0` (complement export, k3s snapshots). Garage has no operator; layout
changes are a documented runbook step (rare: only when sites join/leave).

Immich constraint (verified 2026-07): S3 as primary storage is not supported by Immich;
the live library stays a `zfs-fast`/`zfs-bulk` PVC at S1. Garage holds its backups.

### 6b. Data classes and capacity model

Classify by replaceability, not by service:

1. **Irreplaceable (class 1):** Immich originals, NAS documents/personal/project data,
   all databases, Vaultwarden, the L0 complement. Full 3-2-1: redundant primary at S1,
   one repo copy per site via Garage, optional B2 for crown jewels, sanoid snapshot
   history locally.
2. **Re-acquirable bulk (class 2):** media libraries and similar: local RAID only, no
   cross-site copy. **Currently empty**: the planned NAS content is all class 1
   (2026-07-05 answer), so the class exists in the model, not in the sizing.
3. **Convenience (class 3):** a few household laptops via restic/kopia to per-household
   Garage buckets over the tailnet (phones ride Immich). Optional; the first tier
   dropped if space runs short.

Working model (assumptions flagged, revisit yearly):

| Data | Today | +5 years |
|---|---|---|
| Immich, all 5 households uploading | ~1TB | ~5TB |
| NAS documents + project data | ~1TB *(assumed, confirm)* | ~3TB |
| Laptop backups (class 3, deduped) | ~0.5TB | ~1TB |
| Services, DBs, L0 complement | ~0.1TB | ~0.3TB |
| **Protected total** | **~2.5TB** | **~9TB** |

S1 stores primary + one repo copy (~2x protected: **~18-20TB logical at 5 years**); S2
stores one repo copy (**~9-10TB**). The staged §3b purchases cover this: the first
2x16-20TB mirror carries ~2-3 years; the second pair (or raidz1 conversion) closes the
5-year horizon.

Pool layout: ZFS mirrors, expanded by pairs; mirrors resilver fastest and stage best.
raidz1 with OpenZFS raidz expansion is the capacity-efficient alternative once all four
bays are populated. Monthly scrubs (bit-rot is a real threat model for a decades-scale
photo archive); sanoid snapshot schedules per dataset class.

## 7. Workload placement tiers

Four tiers, expressed as ordinary scheduling config in the cluster definition:

1. **Hardware-pinned** (Home Assistant): nodeSelector to the S1 HA node, USB device
   passthrough, `strict-local` storage. Never fails over; its availability story is the
   node itself plus WAN-outage autonomy (§5).
2. **Critical failover** (Vaultwarden, its Postgres): must survive a site loss in
   minutes. Design below.
3. **Stationary heavy** (Immich + its Postgres, media, monitoring's long storage):
   pinned to a storage site by data gravity; availability target is "restore", not
   "failover"; durability via §8.
4. **Stateless/floating** (dashboards, exporters, bots): free scheduling across zones.

**Vaultwarden failover design (tier 2).** State splits three ways:

- Database: StackGres SGCluster, 3 instances: two in S1 with node anti-affinity (LAN
  streaming, instant local failover for the common node-death case) and one in S2 (async
  over the tailnet, the site-loss survivor). Patroni automatic failover. RPO seconds,
  RTO under a minute.
- `rsa_key.pem`: kix-provisioned Secret, not PVC state (regenerating it only logs out
  sessions, but it is trivially declarative, so declare it).
- Attachments/sends/icons PVC: small. VolSync ReplicationSource (hourly, snapshot-based)
  to Garage plus a ReplicationDestination warm standby at S2. Site loss: pod reschedules
  to S2, mounts the standby copy, DB has already failed over. RPO <=1h on attachments
  only, well inside the accepted envelope.

The same tier-2 pattern generalizes to any future "cannot stay down" service: replicated
DB + kix-declared secrets + VolSync warm standby for residual files.

## 8. Backup and DR (the 124 plan, re-lowered)

124's principles carry over; the engines change per 125's lowering:

- **Capture:** per-PVC VolSync ReplicationSource, `copyMethod: Snapshot` (consistent by
  construction, closing 124's live-read caveat), restic to Garage. Postgres: StackGres
  native backups (WAL + base) to Garage; the 124 deferral flips because object storage
  now exists anyway. Immich's built-in nightly dump stays on as the L5 belt-and-braces.
- **Store:** Garage's one-copy-per-site layout is the store-stage topology policy (every
  object has an off-site copy). Beneath it, sanoid-managed ZFS snapshots on the `bulk` pools
  (a NixOS module, declarative) give delete-protection: a compromised cluster can delete
  bucket contents but not the ZFS snapshot history under them. Garage lacks object-lock,
  so this is the ransomware answer, plus an optional Backblaze B2 delete-less-key bucket
  for the Immich originals only (2-3 EUR/mo) as the off-infrastructure copy.
- **Verify/restore:** unchanged from 112/124: weekly `restic check` equivalents ride the
  engines' CRs, quarterly restore rehearsal until `kix rehearse-restore` exists, runbook
  maintained. Key custody stays stage 0: repo passwords + age keys in two humans'
  password managers before anything else.
- **L0:** CronJob exporting the runtime-accreted complement (out-of-band Secrets,
  operator-created CRs, k3s datastore snapshot) to `cluster-l0`.

## 9. Monitoring

- Prometheus stack stays in-cluster; long-term storage on S1 `zfs-bulk`.
- Alertmanager -> Telegram (the 124 path).
- The VPS is the external vantage: a blackbox/heartbeat probe pinned to zone H alerts
  when a *household* disappears, which in-house monitoring structurally cannot report.
  Add a dead-man's-switch heartbeat (alert that must keep firing) so silent monitoring
  death is itself detected.

## 10. Staged rollout

Each stage is independently useful; no stage blocks on hardware more than one step ahead.

- **Stage 0 (now):** ship 124 stages 0-3 unchanged on the single NUC (key custody, host
  restic to HDD, B2 copy, rehearsal). Data safety first; everything below replaces it
  piecewise.
- **Stage 1 (labels + eyes):** zone labels everywhere; free external uptime check +
  dead-man's switch (healthchecks.io-class). The VPS itself is deferred to stage 3,
  where the automatic failover it enables goes live (§4); pull it forward only if the
  control-plane migration (k3s server moves NUC -> VPS, a deliberate rebuild-from-git
  exercise) feels easier done while the cluster is small.
- **Stage 2 (storage relayer):** reprovision the NUC to ZFS (dormant disko layout),
  deploy LocalPV-ZFS, migrate PVCs off local-path, single-zone Garage on `bulk`, VolSync
  + StackGres-native backups to it. Retire host restic; 124's plan is now fully
  CRD-driven. Archive/annotate 124 accordingly.
- **Stage 3 (DR site + automatic failover):** the S2 storage box + mirror joins (§3b),
  and the Hetzner VPS joins as k3s server (control plane moves off the NUC; the
  rebuild-from-git exercise). Garage re-layouts to one node per site (rf=2, zone-aware),
  the SGCluster gains its S2 replica, warm standby for attachments. First site-loss
  rehearsal: cordon S1's nodes, watch Vaultwarden come back at S2.
- **Stage 4 (S1 densification):** the old laptop joins S1 as the critical-tier node
  (battery = built-in UPS). Critical tier gets in-site HA (node anti-affinity at LAN
  speed). Second S1 mirror pair lands whenever the pool passes ~70%.
- **Stage 5 (hardening, optional):** 3-server control plane (H + 2x S1); per-site block
  replication (LINSTOR or Rook) once S1 reaches 3+ nodes.

## 11. What this demands from kix

- **Zone topology as a first-class cluster fact** (extends `cluster.hardware`): zones,
  per-zone storage classes, per-zone capacity for the 106 capacity-fit check.
- **Packages:** `openebs-zfs-localpv`, `volsync`, `garage` join `kix/packages/`;
  StackGres package grows multi-zone instance spreading + `SGObjectStorage` wiring.
- **The tier model** (§7) is scheduling intent the DSL should express without inventing
  fields: nodeSelector/affinity/topologySpreadConstraints assembled by the cluster
  definition, per 115's interception patterns.
- **108/125 validation:** this cluster exercises L3 (CSI snapshot) + L5 (StackGres,
  Immich dump) lowering with a store-stage topology policy; the first real multi-zone
  input for the state-facts contract, and the empirical answer 125 §7.2 asked for.
- **Netpol:** cross-zone pod traffic must stay inside existing CNP envelopes; verify the
  edge-detection derivations hold when Services span zones.

## 12. Future ambitious horizon (pointers only)

- **Public HTTPS** for share links and non-tailnet guests: Cloudflare tunnel with
  connectors in 2+ households (free failover) or the VPS as reverse proxy; interacts
  with 107's edge model. Explicitly out of scope here per §1.4.
- **Tailscale -> Firezone self-hosting** (the `cluster.nix` TODO) once the cluster can
  host its own overlay control plane without a bootstrapping cycle.
- **Per-site Rook/Ceph** when a site reaches 3+ nodes and wants real block HA locally.
- **Hosting for others / multi-tenancy beyond the family** connects to the tenant-worker
  ideas in the hosting notes (v2/117 commit trail).

## 13. Open questions

Answered 2026-07-05, recorded in §1/§3/§6b: today's NUC is already in the Home Assistant
household (S1 fixed, no role migration); Immich's Postgres stays single-zone at S1
(restore tier); storage concentrates at S1 + S2 instead of spreading across households;
Garage layout management should eventually be a kix-rendered Job applying a declared
layout (preference noted, not designed; runbook until then); budget is
minimize-and-stage; device backups are laptops-only (class 3); planned NAS content is
entirely irreplaceable (class 1, no media tier).

Still open:

1. VPS sizing: does monitoring-on-H fit a CAX11 (4GB) or does it need the next tier?
2. Sync vs async streaming for the Vaultwarden SGCluster: async assumed (RPO seconds);
   revisit only if a corruption scenario demands sync.
3. The §6b capacity model assumes ~1TB of NAS documents/project data today growing to
   ~3TB; confirm against reality before the stage-2 drive purchase.
4. Garage rf=2 write pauses during site outages: acceptable long-term, or upgrade to
   rf=3 (2+1, two extra S1 disks) once budget allows? Revisit after the first real S2
   outage.
5. If a third storage household ever appears: extend Garage to a 3-zone layout (full
   write-HA through any single-site loss)? Needs a concrete driver.
