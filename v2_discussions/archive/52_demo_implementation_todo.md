# Demo Implementation TODO

## Working Document — March 2026

**Status:** Implementation planning
**Target:** VHS demos described in `51_demo_plan.md`
**Depends on:** Existing CLI commands (deploy, gc, rollback, health, status, graph, inspect)

---

## 1. Cluster Definitions

### 1.1 Create `clusters/test-kind-v2.nix`

**Effort:** Trivial
**Status:** Not started

Copy `test-kind.nix` with two changes:
- `message = "hello from kix v2 — updated!";`
- `replicaCount = 2;`

Must produce the same activation name (`test-kind`) so the deploy recognizes it as an update to the same cluster.

### 1.2 Verify both clusters build cleanly

```bash
nix build .#cluster-kind-activation --extra-experimental-features pipe-operators
# swap
nix build .#cluster-kind-activation --extra-experimental-features pipe-operators
```

Both must produce a valid `kix-packages.json`. The diff between them should show exactly 3 modified resources (ConfigMap, Deployment, Service).

**Consideration:** The two cluster files can't both be `test-kind.nix` in the flake at the same time. The `run-demos.sh` script handles the swap via `cp`. Alternatively, we could expose both as separate flake outputs and use `--flake` to switch — but `cp` is simpler and more demo-friendly (the viewer sees "I changed a file and redeployed").

---

## 2. Health Check Enhancements

This is the biggest implementation effort. The current `kix health` is a flat resource-level drift check. The demo needs it to be a **package-aware, graph-walking, blast-radius-reporting tool**.

### 2.1 Design: What `kix health` Should Report

The health check answers three distinct questions:

| Question | What it checks | Current state |
|---|---|---|
| **Integrity** — "Is the graph complete?" | Every resource in the activation DAG exists on the cluster | Partially — reports missing resources, but not grouped by package or graph position |
| **Drift** — "Does the content match?" | Content hash of live resource matches expected hash | Yes — `health.rs` already does this |
| **Liveness** — "Is it actually running?" | Kubernetes readiness/health status of live resources | No — `status` command does this separately, health doesn't |

The demo primarily needs **integrity** (missing resource detection) and **blast radius** (what's affected). Drift is already working. Liveness is a nice-to-have.

### 2.2 Package-level grouping

**Effort:** Medium
**Status:** Not started

Currently `health.rs` reports individual resources. It needs to:

1. Load the `StoreGraph` (already done for hash comparison)
2. Group resources by their `kix.dev/package` + `kix.dev/package-namespace` annotations
3. Compute per-package status: `healthy` (all resources OK), `degraded` (some missing/drifted), `missing` (all resources gone)
4. Display package summaries before resource details

**Output sketch:**
```
Packages:
  ✓ echo-server (echo)    3/3 resources healthy
```

Or when degraded:
```
Packages:
  ✗ echo-server (echo)    2/3 resources healthy — 1 MISSING

Resources:
  echo/ConfigMap/echo-server-config    MISSING
  echo/Deployment/echo-server          in-sync
  echo/Service/echo-server             in-sync
```

### 2.3 Blast radius via graph traversal

**Effort:** Medium-Large
**Status:** Not started

When a resource is missing or drifted, walk the dependency graph **forward** (dependents) to find resources that are **at risk** — they depend on something that's broken.

**Implementation approach:**

1. Build a `ResourceGraph` from the activation's `kix.dev/depends-on` annotations (this code already exists in `cli/kix/src/cluster/graph.rs`)
2. For each unhealthy resource (missing or drifted), walk successors in the graph
3. Mark successors as `at-risk` (they aren't broken themselves, but their dependency is)
4. Roll up to package level: a package is `at-risk` if any of its resources are at-risk due to another package's failure

**Output sketch:**
```
Packages:
  ✗ echo-server (echo)    DEGRADED — 1 missing, 2 at risk

  MISSING:
    ConfigMap/echo-server-config

  AT RISK (depends on missing resources):
    Deployment/echo-server         ← mounts ConfigMap/echo-server-config
    Service/echo-server            ← selects Deployment/echo-server
```

**Key design decisions:**
- "At risk" is not "broken" — the Deployment might still be running (pods have the old ConfigMap cached). But if it restarts, it will fail. The health check should communicate this distinction.
- Cross-package blast radius: if package A depends on package B's resource and that resource is missing, package A should show as `at-risk` too. This is the real value — "your app is fine now, but it depends on something that's broken."
- The graph walk should stop at resources that are themselves verified healthy (hash matches + exists). No need to mark the entire downstream as at-risk if an intermediate resource is confirmed OK.

### 2.4 Verbose mode (`-v` / `--verbose`)

**Effort:** Small
**Status:** Partially exists (shows diffs for drifted resources)

Extend verbose mode to show:

1. **Graph traversal log** — as the health check walks the DAG, print each step:
   ```
   Checking activation root: test-kind
     → Package: echo-server (echo)
       → ConfigMap/echo/echo-server-config ... MISSING
         → Deployment/echo/echo-server ... exists, content in-sync, AT RISK (depends on missing)
           → Service/echo/echo-server ... exists, content in-sync, AT RISK
   ```

2. **Diff output for drifted resources** — already exists, keep it

3. **Dependency chain for at-risk resources** — show *why* something is at risk:
   ```
   Deployment/echo-server is AT RISK because:
     └─ mounts ConfigMap/echo-server-config (MISSING)
   ```

### 2.5 Liveness integration (future — not needed for demo)

**Effort:** Medium
**Status:** Not started, not blocking

Merge the `kix status` readiness information into the health check. A resource can be:
- `healthy` — exists, content matches, K8s reports ready
- `drifted` — exists, content doesn't match
- `unready` — exists, content matches, but K8s says not ready (crashlooping, pending, etc.)
- `missing` — doesn't exist on cluster
- `at-risk` — its dependencies are unhealthy

This gives a complete picture: graph integrity + content fidelity + runtime health.

**Not needed for this demo** because the demo scenario (delete a ConfigMap) produces a `MISSING` state that's clear enough. Liveness matters more for scenarios like "Deployment exists but pods are crashlooping" which is a different demo.

### 2.6 Exit codes

Current: exit 0 (healthy) or exit 1 (drift detected).

Proposed:
- `0` — all resources healthy
- `1` — drift or missing resources detected
- `2` — build/connectivity error

No change needed for the demo, but documenting for completeness.

---

## 3. VHS Tapes and Scripts

### 3.1 Update `demo/vhs/cli-demo.tape`

**Effort:** Medium
**Status:** Existing tape needs rewrite for new narrative

The new tape follows the scene structure in `51_demo_plan.md`:
1. Orientation (list, inspect, graph)
2. First deploy (v1)
3. Health check (all green)
4. Status
5. Deploy v2 (cp + deploy, interactive confirmation)
6. Health + GC (still green)
7. Break something (kubectl delete configmap)
8. Health detects problem (blast radius output)
9. Watch mode (brief `watch` command)
10. Re-deploy to fix
11. Rollback
12. Final health

**Timing considerations:**
- `kix list` is slow (uncached `getFlake`) — either pre-warm or accept ~10s wait
- `kix deploy` with nix eval can take 5-30s depending on cache state — `run-demos.sh` pre-warms
- VHS `Sleep` durations need tuning after a test run
- Total tape should be ~3-4 min (current is ~2.5 min)

### 3.2 Update `demo/vhs/operator-demo.tape`

**Effort:** Medium
**Status:** Existing tape needs extension for v2 deploy + self-heal + rollback

New scenes beyond current tape:
- v2 Activation CR apply → watch operator reconcile changes
- Delete a resource → watch operator self-heal on next reconcile
- Rollback via applying v1 Activation CR
- Final cleanup via deletion

**Operator reconcile timing:**
The default requeue is 300s. For the demo we need faster feedback. Options:
- **(Preferred)** Add a `--reconcile-interval` flag to `kix-operator` (trivial change)
- Patch the Activation CR (e.g., add an annotation) to trigger an immediate reconcile via the kube-rs watcher
- Accept the wait and use VHS `Sleep` with a fast-forward note

### 3.3 Update `demo/vhs/run-demos.sh`

**Effort:** Small-Medium
**Status:** Needs extension

Changes:
- Build **both** v1 and v2 activations (two `nix build` calls, different cluster defs)
- Generate **two** Activation CR YAMLs (v1 and v2 store paths)
- Handle the `test-kind.nix` swap: backup original, cp v2, restore on cleanup
- For operator demo: generate `activation-cr-v2.yaml` with v2 store path
- Possibly lower operator reconcile interval for demo speed

### 3.4 Create `clusters/test-kind-v2.nix`

Already covered in section 1.1 but listing here for completeness — needed before tapes can be written.

---

## 4. Deploy Plan Display Enhancements

### 4.1 Verbose plan output

**Effort:** Small
**Status:** Mostly exists

The current plan display already groups by package and shows resource diffs. Verify that:
- Package-level summary shows "N resources modified/created/deleted"
- Resource-level diffs show field changes (not just "modified")
- The interactive confirmation prompt is clear

May need minor polish for demo readability (colors, alignment, etc.).

---

## 5. Implementation Order

Priority ordered by demo dependency — what blocks the tape from being recorded.

| # | Task | Blocks | Effort | Notes |
|---|---|---|---|---|
| 1 | Create `test-kind-v2.nix` | Everything | Trivial | Copy + edit |
| 2 | Verify v1→v2 diff is clean | Tape writing | Trivial | Build both, check diff |
| 3 | Health: package-level grouping | Scene 3, 8 | Medium | Group by `kix.dev/package` annotation |
| 4 | Health: blast radius graph walk | Scene 8 | Medium-Large | Forward walk from broken resources |
| 5 | Health: verbose graph traversal | Scene 8 | Small | Print traversal steps in `-v` mode |
| 6 | Update `run-demos.sh` | Recording | Small-Medium | Dual build, CR generation, swap logic |
| 7 | Rewrite `cli-demo.tape` | Recording | Medium | New scene structure per plan |
| 8 | Rewrite `operator-demo.tape` | Recording | Medium | Extended scenes + self-heal |
| 9 | (Optional) Operator reconcile interval flag | Operator tape timing | Small | `--reconcile-interval 30s` |
| 10 | (Optional) Health: liveness integration | Future demo | Medium | Merge `status` readiness into `health` |

**Critical path:** 1 → 2 → 3 → 4 → 5 → 6 → 7/8

Items 3-5 (health enhancements) are the real implementation work. Everything else is configuration and scripting.

---

## 6. Health Check — Longer-Term Vision

Beyond the demo, `kix health` should evolve into the primary observability command. Here's the full feature set to consider:

### Modes

- **`kix health <cluster>`** — default, one-shot integrity + drift check
- **`kix health <cluster> --live`** — add liveness (K8s readiness) to the check
- **`kix health <cluster> --deep`** — full content comparison (not just hash), shows exact diffs for all drifted resources
- **`kix health <cluster> --graph`** — verbose graph traversal mode (show the walk)

### Output levels

- **Summary** (default): package-level status table, total counts
- **Verbose** (`-v`): resource-level details, dependency chains for at-risk items
- **Debug** (`-vv`): full graph traversal log, hash comparisons, normalization details

### Blast radius computation

The graph walk should support:
- **Forward blast** — "this resource is broken, what depends on it?" (demo scenario)
- **Backward trace** — "this resource is at risk, why?" (debugging scenario — trace back to the root cause)
- **Cross-package impact** — "package A is broken, which other packages are affected?"
- **Severity levels**: `missing` > `drifted` > `unready` > `at-risk` > `healthy`

### Integration points

- **CI/CD gate**: `kix health --exit-code` for pipeline checks
- **Monitoring**: JSON output (`-o json`) for ingestion into Prometheus/Grafana/alerting
- **Operator**: the operator could run health checks on its reconcile loop and report status on the Activation CR
- **Pre-deploy**: `kix deploy` could run a health check first and warn if the cluster is already degraded before applying changes

### Merkle-walk integrity (from ROADMAP)

The ultimate form of health check: walk the activation DAG from root, verify identity hashes at each node via targeted `GET` (not full `LIST`). Requires enriching `kix.dev/depends-on` with resource hints (`hash:kind/namespace/name`). Two modes:
- **Fast integrity**: graph walk only (hash comparison)
- **Deep drift**: content-hash comparison at each node

This is the "cryptographic audit" capability described in `29_compiler-design.md` section 8.3.
