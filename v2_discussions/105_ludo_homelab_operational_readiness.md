# 105: Ludo homelab — operational readiness for production

**Status:** Brainstorm / RFC — operator checklist; most kix-side gaps spun out.
**Relevance:** Active
**Related:** `90_ludo_north_star_ideation.md`, `101_monitoring_provider_landscape.md`, `102_auto_monitoring_wiring.md`, `67_stateful_migration_orchestration.md`, `104_adam_customer_migration_readiness.md`, `interesting_thoughts/49_topology_aware_monitoring.md`
**Supersedes:** none — new angle (operator self-readiness, not demonstrator narrative).
**Spin-outs / status of the B-list (see Part B for details):**
- B1 → `108_backup_capability_contract.md` (RFC, Phase 0 surface defined).
- B2/B9 → `110_alerts_as_graph_resources.md` (RFC).
- B3 → `107_overlay_edge_exposure.md` (RFC, replaces `meta.exposure`).
- B4 → **shipped**: `boundedResources` rule in `kix/lib/rules/reliability.nix`.
- B5 → still open (pure docs in `cli/README.md` + `kix-migration` skill).
- B6 → **designed**, implementation pending: addendum in `77_secrets_implementation_plan.md`.
- B7 → **shipped**: `cluster.maintenance` + `cluster.out.maintenance` in `kix/lib/modules.nix` / `kix/lib/eval/cluster.nix`. Routing-side wiring lives in 110 §7.
- B8 → folded into `106_ops_lifecycle_verbs_and_capacity_check.md` §1.3.

## Why this doc

Doc 90 frames ludo as a *demonstrator narrative* (what story does ludo tell to outsiders). This doc is the complementary view: what does Luca actually need to run ludo on a real k3s node and sleep at night. The intersection between those two views is where kix gaps live.

Audience: an operator who is fluent in Kubernetes-as-developer but new to Kubernetes-as-on-call. The output of this doc is (a) a checklist Luca can work through, and (b) a list of items that should be promoted to ROADMAP because kix should make them easier.

## Operator profile (recap of intake)

- **Topology:** single k3s node now; second node planned same-site as HA peer.
- **Stakes:** personal services Luca relies on; data that cannot be lost; demonstrator / kix dogfooding; access for outside via Tailscale-style overlay.
- **Downtime tolerance:** tens of minutes during incidents; planned maintenance windows are acceptable.
- **State today:** empty fresh k3s, external ZFS drive available for local backup target; second machine / object storage later.
- **Comfort:** mostly new to operating Prometheus / backup tooling / cluster upgrades.
- **Scope of "production":** ludo platform stack + remote-access plane + monitoring/backups/alerting infra (treated as kix packages, not bolted on).
- **Deploy path:** manual `kix deploy` from laptop now, GitOps/operator later.
- **Alerting:** phone push (ntfy / Telegram).
- **Edge:** Tailscale-only; no public ingress, no Let's-Encrypt-on-public-DNS pain.

This profile is opinionated and matters: the gap list below is shaped by it. A different profile (multi-tenant, public ingress, no maintenance windows) would produce a different doc.

## Part A — operator concerns, by subsystem

For each subsystem: *what good looks like at this stakes level*, *minimum viable*, *what kix already gives us*, *what's missing*.

### A1. Identity, secrets, disaster recovery

**Risk:** if the node dies and you can't decrypt secrets, the cluster cannot be rebuilt — the cluster definition is useless without the keys.

**What good looks like:**
- SOPS / age private key exists in **at least two places not on the cluster node** (e.g. Yubikey + offline encrypted USB + password manager attachment).
- A documented "rebuild cluster from scratch" rehearsal that you've actually done once.
- Cluster CA / kubeconfig also recoverable (k3s regenerates them on `--cluster-reset`, but anything signed by the cluster CA is not — e.g. issued mTLS certs).

**Minimum viable:**
- SOPS key in the password manager + on a second offline medium.
- Written runbook: "given a fresh node, here's how to restore."

**What kix gives us:** SOPS hydration in `cli/` (doc `77_secrets_implementation_plan.md`). Encryption at rest of secrets is the *deploy* problem, not the *recovery* problem.

**Gaps (potential kix work):**
- No "bootstrap from zero" flow documented in `cli/README.md`. The skill `kix-migration/SECRETS.md` covers migration but not blank-slate disaster recovery.
- No assertion at eval time that the operator running `kix deploy` *can* decrypt every referenced secret — failures surface late.

### A2. Storage durability and backups

**Risk:** k3s default `local-path` lives on the root disk. Disk failure = total loss. Even snapshotting tools that run *on* the cluster don't survive node death.

**What good looks like at this stakes level:**
- Application-aware backups for stateful workloads (Postgres → CNPG/StackGres logical backups, not "snapshot the PVC and pray").
- An off-node target. ZFS drive plugged into the node is "off-PVC" but **not off-node** — a kernel panic that corrupts the FS will hit both. Treat the ZFS drive as the *staging* target, with replication to a second machine or cheap object storage as the durable copy.
- Restore is rehearsed. Untested backups are theatre.

**Minimum viable for week-1:**
- StackGres/CNPG configured with logical backup to ZFS drive, scheduled.
- Restic (or kopia) backing up `/var/lib/rancher/k3s/storage/` and the ZFS staging area to ZFS itself, then `zfs send` to a removable medium weekly until the second machine arrives.
- One end-to-end restore exercise on day 1 — restore one DB, one file PVC, into a kind cluster.

**Concrete storage layout (1TB SSD on-node + 1TB external HDD):**

Phased, so the day-1 setup is boring and migrates cleanly later.

- **Phase 1 (now → D-day):**
  - SSD: k3s `local-path` provisioner → all PVCs land here.
  - HDD: ZFS pool mounted at `/srv/backup`. Restic repository on it.
  - App-aware backup for Postgres (CNPG/StackGres → logical dump → restic → HDD), daily.
  - File PVCs: nightly `restic backup` of `/var/lib/rancher/k3s/storage/` to the HDD repo.
  - Daily ZFS snapshot of the HDD dataset (defence in depth: a bad restic run can't overwrite a good one).
  - One end-to-end restore rehearsal before declaring "production".
- **Phase 2 (when a second machine / object storage exists):** keep the same restic shape, change destination to a remote repo. Local HDD repo becomes a fast-restore mirror; remote is the durable copy.
- **Phase 3 (when the second *node* arrives):** migrate primary PVCs to Longhorn (or equivalent CSI) — single-replica → multi-replica is a config flip, not a re-architecture. Backup destination stays the same.

Two anti-patterns to avoid: (a) putting PVCs directly on the HDD — spinning rust under Postgres is misery, and it conflates primary storage with backup target; (b) treating HDD-on-the-same-node as durability — it's *staging* until a second failure domain exists.

**What kix gives us:** nothing structural for backups today. `ludo/databases.nix` exists but no backup contract. Doc 90 §L3 calls out "backup contract" as an open story.

**Gaps (kix work, candidates for ROADMAP):**
- **Backup as a first-class capability contract.** A `meta.backup` intent on resources/instances ("this is stateful, should be backed up to <target>"), rendered by the storage flavor in the cluster (parallels `meta.monitoring` from doc 101/102). Off-node target is a cluster-level concern, not a package concern (matches doc `63a_storage_as_cluster_concern`).
- **Build-time check:** any workload with a PVC that is *not* matched by a backup intent should be a structured warning. Same shape as doc 95 netpol-validation.
- Schedule and retention should be expressible declaratively, not as a free `cron:` field that drifts from what the operator actually wants.

### A3. Monitoring & alerting (push-to-phone)

**Risk:** silent failure. Stateful workload broken at 02:00 and you find out via "the dashboard isn't loading" two days later. By then logs have rolled.

**What good looks like:**
- A *small* set of alerts that you actually trust — high-signal, low-noise. The classic homelab failure is too many alerts → mute everything → miss the real one.
- Push channel that wakes you up when needed and shuts up otherwise (ntfy with priority levels, or Telegram bot).
- Black-box probes for the things that matter to *you* (can I reach my readdeck instance? does Postgres respond?), not just node-exporter CPU%.
- Dashboards exist but are secondary.

**Minimum viable starter alert set (ten items max):**
1. Node down / kubelet not ready > 5m.
2. Disk usage on root filesystem > 85% (sustained).
3. Disk usage on ZFS drive > 85%.
4. Pod CrashLoopBackOff > 15m for any pod in any of {a small list of important namespaces}.
5. PVC near full (> 90%) for any tracked workload.
6. Postgres primary down (StackGres/CNPG-aware probe).
7. Last successful backup older than configured RTO (e.g. > 36h for daily backups).
8. Cert nearing expiry (< 14d).
9. Tailscale node unreachable from outside (synthetic check, only if you have a second tailnet member to probe from).
10. OOM-killed in last 1h.

That's the homelab list. Anything beyond that earns its place by firing exactly when it should.

**What kix gives us:** doc 101 surveys provider landscape; doc 102 plans `meta.monitoring` auto-wiring. Neither is shipped yet, and both focus on *metrics scrape config*, not on *the alert rule set*.

**Gaps:**
- **Alert pack as a kix concept.** A package that brings a workload should be able to declare "here are the alerts that mean this is broken" the same way it declares ServiceMonitors. Today this is in Helm-chart land and not portable.
- **A baseline cluster-operations alert pack** (the 10 above) shipped as a kix package, parameterized by the cluster (which namespaces matter, which PVCs to track, what's the backup RTO).
- **Alertmanager routing as kix config**: the routing tree (priority → ntfy topic, low-priority → email digest) is *exactly* the thing that should be DSL-driven, because today it's nested YAML that nobody touches once it works.

### A4. Certificates

**Tailscale-only simplifies the public-facing story** — no Let's Encrypt rate limit pain, no public DNS. But internal certs still exist:
- Cluster PKI (k3s manages this, but expiry is real — k3s rotates on restart by default; *check the k3s docs for your version*).
- StackGres/CNPG mTLS between PG nodes.
- Anything signed by cert-manager's internal issuer (e.g. webhooks, mutual auth between services).

**Minimum viable:**
- cert-manager already in `kix/packages/cert-manager/` — keep it as the internal CA.
- An alert on "cert expiring in < 14d" (catches both cert-manager-issued and the cluster CA via `kube-apiserver-cert` metric).

**Gaps:** none structural; this is operator hygiene, not kix gap. Worth a runbook entry.

### A5. Networking and remote access

**Tailscale-only edge** means:
- No `Service type=LoadBalancer` exposed externally; everything is `ClusterIP` reachable via the Tailscale operator (or a Tailscale subnet router).
- DNS for service names: MagicDNS handles tailnet-side. Inside the cluster, normal kube-dns / coredns.
- Kubectl access from outside: Tailscale → kube-apiserver via subnet route, or Tailscale operator's `tailscaled` subnet exposure.

**What good looks like:**
- Tailscale operator running in-cluster, configured via kix (declarative) — *not* an out-of-band Helm install.
- A second admin path (LAN-only kubectl with kubeconfig pinned to LAN IP) so a Tailscale outage doesn't lock you out of your own cluster.
- A single explicit list of which services are exposed on the tailnet, declared in the cluster definition.

**Gaps:**
- **`ludo/` doesn't have a Tailscale package today.** This needs a kix package (probably wrapping the official `tailscale-operator` Helm chart via doc 87's helm-integration v2). Should be in `kix/packages/tailscale-operator/`.
- **Service-exposure intent.** `meta.exposure` (similar to monitoring/backup intents) declared per-service: "expose this on the tailnet as foo.tailnet.ts.net". Closes the loop with doc 97 service-contract primitives.

### A6. Node maintenance (single-node reality)

**Risk classes:**
- OS package upgrades (unattended-upgrades on Debian/Ubuntu can reboot mid-deploy).
- Kernel upgrades (often need reboot — k3s + workloads come back up *if* the storage is rooted properly).
- Disk fills (logs, container images, ZFS pool full → CoW failure → wedged FS).
- Power: surprise reboots. UPS is cheap insurance for a single-node prod homelab; not optional at this stakes level.

**Minimum viable:**
- UPS with `nut`/`apcupsd` and a clean shutdown trigger.
- Disable unattended-upgrades on the host *or* tightly scope it (security only, no auto-reboot). Reboots are an operator action with a maintenance window.
- A documented monthly "maintenance window" runbook: drain (single node = `kubectl cordon` doesn't help, but stop sensitive workloads first), upgrade OS, reboot, verify.
- Resource reservations: `--kubelet-arg=system-reserved=...` so the kernel and k3s don't get OOM-killed by user workloads. Critical on single-node where eviction isn't an escape valve.

**Gaps:** out of kix scope (host-level). But:
- **Maintenance-mode marker in cluster definition.** Doc 90 §M1 mentions this. A way to flag "the cluster is in a maintenance window, expect alert noise, suppress non-actionable pages" — drives Alertmanager silence + the operator UI.

### A7. k3s and Kubernetes upgrades

**Risk:** k3s upgrades have failure modes that aren't visible until pods restart (CRD version skew, removed APIs).

**What good looks like:**
- Upgrade k3s on a planned cadence (every 2–3 minor releases, not every patch). Single-node upgrades are easier than multi-node — when the second node arrives, this gets harder.
- Pin k3s version explicitly; don't follow `latest`.
- Have a rollback plan: snapshot the node's `/var/lib/rancher/k3s/server/db/` (etcd embedded) and the ZFS dataset before upgrade; if the upgrade wedges, restore.
- Have a *kind* mirror of the same k3s version → smoke-test ludo there before the homelab upgrade.

**Gaps:**
- Doc `cluster-kind-upgrade-broad.nix` and `cluster-kind-upgrade-small.nix` already prototype this in kix — they should evolve into a **first-class "rehearse upgrade" workflow** where the operator points at "current cluster state + target version" and gets a kind-based dry run.
- Connects directly to doc 67 (stateful migration orchestration).

### A8. Application lifecycle (manual `kix deploy` for now)

**Risk while manual:** the laptop is the SPOF. Lose the laptop, lose `kix deploy` capability until you re-bootstrap the SOPS key and the toolchain.

**Minimum viable:**
- A second machine (or a documented bootstrap script) that can run `nix develop && kix deploy` given the SOPS key.
- Cluster definition + secrets in a private git remote, not just on the laptop.
- A pre-deploy sanity gate: `nix build` succeeds, `kix-diff` against current cluster shows expected diff (and only that diff). The user already does `./scripts/kix-diff.py` — make this part of the documented runbook.

**Gaps:** these are documentation gaps in `cli/README.md` and the `kix-migration` skill, not engine gaps. Worth listing in ROADMAP under "operator UX docs".

### A9. Capacity / resource pressure

**Single-node reality:** you cannot evict to "another node". OOMs become reboots if they hit the kernel; pod evictions just churn until they OOM again.

**Minimum viable:**
- `requests` and `limits` set on every workload. The kix DSL should make missing requests/limits a build-time warning at this maturity level.
- A small headroom alert: "node allocatable < 20% free" sustained.

**Gaps:**
- **Build-time warning for un-bounded workloads.** Same shape as the netpol/monitoring intent checks; a flavor-defined policy "all workloads must declare requests/limits", with structured diagnostic when violated. Reuses doc 80 (structured diagnostics) machinery.

### A10. Logs

**Risk:** when something breaks, you reach for `kubectl logs` and find that the pod restarted ten times and the *useful* log was in the second restart, gone.

**Minimum viable:**
- Persistent log shipping to *somewhere* (Loki on the same node — circular if the node is the problem; or rsyslog → file on the ZFS drive).
- Don't go big on log infra at this stakes level. Even just "kubectl logs --previous" + `journalctl -u k3s` on the host covers 80% of incidents.

**Gaps:** none kix-side at this stakes level. Future: Loki package + monitoring intent rendering, but tracked separately.

### A11. Time / clock

Surprisingly common homelab failure mode. NTP drift breaks: cert validation, etcd, anything with a TTL.

- Make sure `chrony` or `systemd-timesyncd` is healthy. Add a one-line alert: "node clock skew > 5s".

### A12. Multi-node transition (when the second node arrives)

This is "Phase 2" — out of scope for v1 of this doc, but listed so it isn't forgotten:
- k3s HA control plane (embedded etcd → 3 nodes minimum for proper HA, 2 nodes is *worse* than 1).
- Storage replication (Longhorn / OpenEBS replicated mode) becomes the natural answer.
- Anti-affinity for stateful workloads.
- The single-node simplifications above (no eviction headroom, manual maintenance windows) become inadequate.

Capture in `interesting_thoughts/` once the second node is on the horizon.

## Part B — kix gap inventory (candidates for ROADMAP)

Concerns from Part A that are *not* one-time operator setup but should become kix work. Ordered by leverage.

| # | Gap | Source | Status | Where it lives now |
|---|-----|--------|--------|---------------------|
| B1 | **Backup as a capability contract** (`meta.backup` intent, flavor renders, build-time warning for unmatched stateful workloads) | A2 | Spun out — RFC | `108_backup_capability_contract.md` |
| B2 | **Baseline cluster-ops alert pack** | A3 | Spun out — RFC | `110_alerts_as_graph_resources.md` (`cluster-baseline-alerts` package) |
| B3 | **Tailscale-operator kix package** + service exposure | A5 | Spun out — RFC; `meta.exposure` rejected | `107_overlay_edge_exposure.md` (engine-side wiring on `kix.expose`) |
| B4 | **Build-time warning for un-bounded workloads** (no requests/limits) | A9 | **Shipped** | `kix/lib/rules/reliability.nix` (`boundedResources`, scorecard-override-parameterized) |
| B5 | **Bootstrap-from-zero documentation** in `cli/README.md` and `kix-migration` skill | A1 | Open — pure docs | not started |
| B6 | **Pre-deploy decryptability assertion** | A1 | Designed; impl pending | `77_secrets_implementation_plan.md` (addendum) |
| B7 | **Maintenance-mode marker** | A6 | **Shipped (surface)** — routing wiring in 110 §7 | `cluster.maintenance` + `cluster.out.maintenance` in `kix/lib/modules.nix`, `kix/lib/eval/cluster.nix` |
| B8 | **First-class "rehearse upgrade" workflow** | A7 | Folded | `106_ops_lifecycle_verbs_and_capacity_check.md` §1.3 |
| B9 | **Alertmanager routing as kix config** | A3 | Spun out | `110_alerts_as_graph_resources.md` §4 (`alertmanager-routing` package) |

Items not in the table because they are *operator hygiene*, not kix gaps: A4 certs, A6 host UPS/upgrades, A11 NTP, A12 multi-node transition.

## Prioritized roadmap

### D-day (before calling ludo "production" on this k3s node)

These are non-negotiable; they are what makes the difference between "running" and "production".

1. **SOPS key off-node, in two places.** (operator)
2. **One end-to-end restore rehearsal** — restore a backed-up DB into kind from the ZFS-staged backup. (operator + kix B1 stub)
3. **UPS + clean shutdown.** (operator)
4. **Resource reservations on k3s** so the host doesn't OOM. (operator)
5. **The 10-alert pack wired to ntfy.** (kix B2 — even hand-rolled v0)
6. **Tailscale operator deployed and a synthetic "can I reach my service from outside" probe.** (kix B3)
7. **Documented runbook: "node died, here's how I rebuild from git + SOPS key + last backup."** (operator + B5)

### D+1 month

- Backup intent + build-time warning (B1 fully).
- Pre-deploy decryptability assertion (B6).
- Build-time warning for un-bounded workloads (B4).
- Maintenance-mode marker (B7).
- Alertmanager routing as kix config (B9).

### D+1 quarter

- "Rehearse upgrade" workflow (B8) — drives confidence on k3s upgrades.
- Multi-node transition design doc (separate doc, when second node lands).
- Logs: pick Loki vs. just-journald, add as a kix package if Loki.
- Off-site backup target (second machine or B2/Hetzner) — once it exists, change the backup destination, not the design.

## Open questions

1. ~~Should the "10-alert pack" be one kix package or N capability-rendered alerts?~~ — answered in doc 110: both, with `cluster-baseline-alerts` for the five rules nobody else owns and capability packages owning the rest via `scope.mkAlert` / `scope.mkAlerts.<recipe>`.
2. **Does Tailscale-only edge let us drop cert-manager from `ludo/cluster.nix`?** Internal CA still useful for mTLS, but worth questioning whether ludo *needs* it on day 1.
3. ~~Where do backup destinations live in the DSL?~~ — answered in doc 108 §4.2: `cluster.backup.destinations`, matching `63a`.
4. **Should the operator (kix activation operator) be ludo's first "self-hosted operator" target?** Doc 90 §M3 raises this. Decoupled from this doc's day-one scope but should be revisited at D+1 quarter.
5. **What is the SOPS-key-recovery story when keys are split across operator and customer (multi-team)?** Out of scope here, but doc 104 customer-readiness needs to coordinate.

## What this doc is *not*

- Not a kix design doc. The kix items here are pointers to where new design docs are needed (B1–B9).
- Not a multi-node design. That's a separate doc when the second node materializes.
- Not a public-ingress design. Tailscale-only is the chosen edge; revisit if that changes.
