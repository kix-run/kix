# V4 Capability Migration Plan

## Context

kixpkgs currently has a Level 3 monitoring module (`modules/monitoring.nix`)
where charts declare `monitoring.targets.*` and the module creates
ServiceMonitors. V4 replaces this with a **capability interface** — charts
declare abstract intent (`capabilities.monitoring.*`), implementation modules
write back metadata (`.output.labels`, `.output.annotations`) and create
resources. This is the architectural foundation for all future cross-cutting
concerns.

The migration is big-bang (all 3 charts change together) and experimental —
learning by doing.

**Reference doc:** `DEPENDENCY_TRACKING_V4/12_Answers_And_Decisions.md`

---

## Rules to follow throughout (from doc 12)

1. **Implementation modules must NEVER read from `.output.*` fields.** Creates
   infinite recursion. Error messages are unhelpful — use `--show-trace`.
2. **Charts read output, never write it.** Charts may read
   `capabilities.monitoring.*.output.labels`; they must never set `.output.*`.
3. **Submodule must declare both input and output fields with defaults.**
4. **One implementation module per capability.** `monitoring-prometheus.nix` is
   the sole writer to `capabilities.monitoring.*.output.*`.
5. **Don't name a target "enabled".** `attrsOf` namespace collision.
6. **Implementation modules must NEVER read `config.manifests` to produce
   `config.manifests` entries.** Fixpoint cycle. Flow is:
   capabilities → implementation → manifests.
7. **Use `lib.recursiveUpdate` or `mkMerge`, never raw `//`** for nested
   attrset writeback. (`//` is shallow — drops nested keys silently.)
8. **Don't normalize port names.** Charts use `metrics`,
   `tcp-prometheus-servicemonitor`, `http-metrics`. Pass through as-is.
9. **StatefulSet `serviceName` is immutable.** Pod DNS depends on it.
   Combinators must never touch it.
10. **Guard conditions on output reads must exactly match the `mkIf` on the
    target declaration.** If they drift, you get attribute-missing crashes when
    monitoring is disabled. Add comments tying the two together.

---

## Phase 0: Snapshot Baseline

Before touching any code, capture current output for later diffing:

```bash
for v in coredns coredns-prometheus valkey valkey-full cert-manager cluster-example; do
  echo "$v: $(nix build .#$v --no-link --print-out-paths)"
done > /tmp/kix-v4-baseline.txt
```

This lets you verify non-monitoring resources are byte-identical after
migration.

---

## Phase 1: Capability Interface

**Create `modules/capabilities/monitoring.nix`**

Declares two option groups:

1. **Cluster-level switches** at `monitoring.*`:
   - `monitoring.enabled` (bool, default false)
   - `monitoring.provider` (enum `["prometheus" "none"]`, default `"prometheus"`)
   - `monitoring.defaultInterval` (str, default `"30s"`)

2. **Capability submodule** at `capabilities.monitoring.*` (`attrsOf submodule`):
   - **Input fields** (charts write): `serviceName`, `namespace`, `portName`,
     `selector`, `port` (int, optional), `path` (str, default "/metrics"),
     `interval` (nullOr str, default null)
   - **Output fields** (implementations write): `output.labels` (attrsOf str,
     default {}), `output.annotations` (attrsOf str, default {})

Design notes:
- Keep `portName` (string) as the primary port identifier —
  `mkServiceMonitor` needs it as a string, and all 3 charts already declare
  it. Add `port` (int) as an optional field for future use. **This deviates
  from doc 07A's abstract interface** (which omits `portName` and `selector`)
  — pragmatic compromise to minimize migration risk. Can refine later.
- Keep `selector` — the implementation needs it for ServiceMonitor label
  matching. Removing it would require selector inference, which is complex.
- Keep `interval` per-target — valkey may need different scrape intervals.
- Drop `enabled` per-target — charts use `lib.mkIf` on the whole declaration
  instead (avoids `attrsOf` namespace collision).
- No `config` section in this file — it's pure interface.
- **Note on `monitoring.enabled`**: The old `monitoring.nix` already declares
  this option. Since we keep `monitoring.nix` during migration (Phase 3),
  the new capability module must NOT redeclare `monitoring.enabled` or
  `monitoring.defaultInterval` — those come from the old module until it's
  deleted. Only add `monitoring.provider` (new).

**Files:** Create `modules/capabilities/monitoring.nix`

---

## Phase 2: Implementation Module

**Create `modules/implementations/monitoring-prometheus.nix`**

Does three things:
1. Reads `config.capabilities.monitoring.*` input fields
2. Writes `.output.labels` and `.output.annotations` back to each target
3. Creates ServiceMonitor per target in `config.manifests`

The logic is almost identical to `modules/monitoring.nix` (lines 170-192).
Key differences:
- Adds writeback: `output.labels."kix.monitoring/scrape" = "true"` and
  port/path annotations
- Reads from `capabilities.monitoring` instead of `monitoring.targets`
- Gates on `cfg.enabled && cfg.provider == "prometheus"`

Critical implementation details:
- The writeback lambda reads `target.portName`, `target.port`, `target.path`
  (inputs) and writes `target.output.*` (outputs) — **never read `.output.*`**
- Use `lib.mapAttrs` for writeback (same keys), `lib.mapAttrs'` for manifests
  (new keys via `lib.nameValuePair`)
- **No `filterAttrs` needed.** When `mkIf false` suppresses a target, the key
  simply doesn't exist in the attrset — there's nothing to filter. An empty
  `{}` would be a type error (required fields missing), not a valid target.
- ServiceMonitor manifest keys must use the same naming convention as the old
  module: `"monitoring-${name}-servicemonitor"` — otherwise golden files and
  assertions need extra updating.

**Known compromise — metrics port duplication:** Charts declare `port = 9153`
in the capability AND have the same port hardcoded in the container spec. This
is the duplication Luca flagged in 10C. It's unavoidable without `withMetrics`
(deferred). Document it in comments; resolve when combinators can read ports
from containers.

**Files:** Create `modules/implementations/monitoring-prometheus.nix`

**Checkpoint:** Test in `nix repl` with a synthetic target before proceeding —
verify no infinite recursion and that `.output.labels` populates.

**Commit** after this phase.

---

## Phase 3: Wire Up Module System (Dual-Path)

**Modify `modules/default.nix`** — **ADD** new imports alongside the existing
`monitoring.nix`:

```nix
imports = [
  ./cluster.nix
  ./registry.nix
  ./monitoring.nix              # KEEP during migration — different option namespace
  ./capabilities/monitoring.nix
  ./implementations/monitoring-prometheus.nix
  ./network-policy.nix
];
```

The old module uses `monitoring.targets.*`; the new uses
`capabilities.monitoring.*` — different option namespaces, no conflict. This
lets us migrate charts one at a time with per-chart verification.

**Important:** If the new capability module declares `monitoring.enabled` or
`monitoring.defaultInterval`, it will conflict with the old module. Only
declare NEW options (`monitoring.provider`) in the capability module; let the
old module own `monitoring.enabled` and `monitoring.defaultInterval` until
it's deleted.

**Files:** Modify `modules/default.nix`

**Checkpoint:** `nix flake check` — should pass with zero behavior change
(new modules have empty defaults, no chart writes to them yet).

**Commit** after this phase.

---

## Phase 4: Migrate Charts

Order: **CoreDNS → Valkey → cert-manager** (simplest to most complex).
Build each chart's monitoring variant immediately after migrating it.

### New invariant to maintain

V4 introduces chart READ dependencies on the capability system. Today, charts
only WRITE to `monitoring.targets.*` — they never read from monitoring. In V4,
charts read `config.capabilities.monitoring.*.output.labels` to merge into
Service metadata. **Every output read must be guarded**, and **every guard
must exactly match the `mkIf` on the corresponding target declaration.** If
they drift, the chart crashes when monitoring is disabled. Add comments tying
each guard to its target declaration.

### 4a: CoreDNS (`pkgs/coredns/resources.nix`)

Two changes:

1. **extraConfig** (~line 406): Replace `monitoring.targets.coredns` with
   `capabilities.monitoring.coredns`. Add `port = 9153` and
   `path = "/metrics"` to the existing fields.

2. **metricsService** (~line 231): Merge capability output into Service
   metadata. Guard with the same condition that gates the capability
   declaration:
   ```nix
   # Guard MUST match the mkIf on capabilities.monitoring.coredns above
   monitoringLabels = if (hasPrometheus && cfg.prometheus.service.enabled && cfg.prometheus.monitor.enabled)
     then config.capabilities.monitoring.coredns.output.labels
     else {};
   ```

**Checkpoint:** `nix build .#coredns-prometheus --show-trace`

### 4b: Valkey (`pkgs/valkey/resources.nix`)

1. **extraConfig** (~line 877): Replace `monitoring.targets.valkey` with
   `capabilities.monitoring.valkey`. Add `port = 9121`,
   `path = "/metrics"`. Drop `interval = null` (the implementation handles
   defaults).

2. **metricsSvc** (~line 683): Merge capability output into metrics Service
   metadata. Same guarded pattern.

Note: Valkey's PodMonitor and PrometheusRule remain per-chart — only the
ServiceMonitor moves to the capability system.

**Checkpoint:** `nix build .#valkey-full --show-trace`

### 4c: cert-manager (`pkgs/cert-manager/resources.nix`)

Three targets (~lines 574-591):

1. **extraConfig**: Replace all three `monitoring.targets.*` with
   `capabilities.monitoring.*`:
   - `cert-manager` (controller): port 9402, portName
     `tcp-prometheus-servicemonitor`
   - `cert-manager-webhook`: port 9402, portName `metrics`
   - `cert-manager-cainjector`: port 9402, portName `http-metrics`, gated on
     `cfg.cainjector.enabled`

2. **Three Services**: Merge capability output labels/annotations into
   controller Service, webhook Service, and cainjector Service. The cainjector
   merge needs a guard on `cfg.cainjector.enabled`. Note: controller and
   webhook targets are unconditional (no `mkIf`), so their output can be
   read without guards.

**Checkpoint:** `nix build .#cert-manager --show-trace`

### 4d: Delete old monitoring path

After all three charts are migrated, verify the old path is dead:
- Grep for `monitoring.targets` across all `.nix` files — should only appear
  in `modules/monitoring.nix` itself and test assertions.
- Remove `./monitoring.nix` from `modules/default.nix` imports.
- Move `monitoring.enabled` and `monitoring.defaultInterval` options into
  `modules/capabilities/monitoring.nix`.
- Delete `modules/monitoring.nix`.

**Files:** Modify `pkgs/coredns/resources.nix`, `pkgs/valkey/resources.nix`,
`pkgs/cert-manager/resources.nix`, `modules/default.nix`; delete
`modules/monitoring.nix`

**Commit** after this phase.

---

## Phase 5: Update Cluster Configs and Tests

### 5a: Cluster configs

- `clusters/example.nix` (~line 50): Add `monitoring.provider = "prometheus"`
  (or set default in capability interface so this isn't needed).
- `clusters/test-full.nix`: Same if needed.
- `clusters/test-minimal.nix`: No change (monitoring disabled).

### 5b: Test assertions in `flake.nix`

Every reference to `mon.targets.*` or `fmon.targets.*` must change to
`capabilities.monitoring.*`. **Do a project-wide grep for `mon.targets`,
`fmon.targets`, and `monitoring.targets` before starting** — catch echo
statements and string interpolations, not just assertions.

Specific locations:

- **cluster-example check** (~lines 551-587): Replace
  `mon.targets.valkey.serviceName` → `caps.valkey.serviceName` etc. Add new
  assertions for writeback:
  `caps.coredns.output.labels ? "kix.monitoring/scrape"`.
- **cluster-full check** (~lines 609-612): Replace
  `fmon.targets ? coredns` → `fullCaps ? coredns` etc.
- **cluster-minimal check** (~line 645): Replace
  `monitoring.targets == {}` → `capabilities.monitoring == {}`.
- **Echo statements** (~lines 586-587): Update string interpolations to
  reference new paths. These fail at build time with unhelpful errors if
  missed.

**Files:** Modify `clusters/example.nix`, `flake.nix`

**Checkpoint:** Run structural checks only (golden files not yet updated):
```bash
nix build .#checks.aarch64-darwin.cluster-example --show-trace
nix build .#checks.aarch64-darwin.cluster-full --show-trace
nix build .#checks.aarch64-darwin.cluster-minimal --show-trace
```

**Commit** after this phase.

---

## Phase 6: Golden Files

```bash
./scripts/update-golden.sh
git diff tests/
```

**Expected changes:**
- Metrics Services gain `kix.monitoring/scrape: "true"` label and port/path
  annotations
- ServiceMonitors may have minor label differences
- **All non-monitoring resources must be byte-identical** — diff against the
  Phase 0 baseline to verify

**Checkpoint:** `nix flake check` — all 42 checks pass.

**Commit** after this phase.

---

## Phase 7: Proof-of-Concept Combinators

**Modify `lib/default.nix`** — add `combinators` attribute set inside
`makeExtensible`:

Functions to add:
- `mkGroup`: Wraps an attrset of resources into a group. Pure passthrough —
  no `_extraConfig` (deferred per doc 12).
- `groupToManifestList`: Converts group → `manifestList` format.
- `optionalPipe`: `cond -> f -> x -> if cond then f x else x`
- `withAutoscaler`: Sets `spec.replicas = null` on workload, adds HPA
  resource. Uses `lib.recursiveUpdate` for nested field modification.
- `withPDB`: Adds PodDisruptionBudget resource using workload's selector
  labels.

Not included in this phase: `withRole` (RBAC already well-served by
`mkRoleSet`; adding it to the pipe system can happen alongside the deferred
RBAC DSL work) and `withMetrics` (port-duplication design flaw flagged by Luca
is unresolved; needs single-source-of-truth for ports before building).

These are pure functions over attrsets — no module system involvement. Charts
are NOT refactored to use them yet. They're available in kixlib for testing
and future use.

**Caveat: `lib.recursiveUpdate` replaces lists, doesn't merge them.** Fine for
`withAutoscaler` (sets scalar `replicas`) and `withPDB` (adds new resource).
But a future `withSidecar` that tries to add to `spec.containers` via
`recursiveUpdate` would silently DROP all existing containers. Document this
prominently for future combinator authors.

**Files:** Modify `lib/default.nix`

**Checkpoint:** Test in `nix repl` — create a group, pipe through
`withAutoscaler`, verify HPA appears and replicas nulled. Then
`nix flake check`.

**Commit** after this phase.

---

## Verification

After all phases:

1. `nix flake check` — all 42 checks pass (golden files updated)
2. `nix build .#cluster-example` — cluster builds successfully
3. Diff against Phase 0 baseline — only monitoring-related resources changed
4. Inspect a ServiceMonitor — uses generic `kix.monitoring/scrape` selector
5. Inspect a metrics Service — has `.output.labels` merged in
6. Test in `nix repl` —
   `config.capabilities.monitoring.coredns.output.labels` returns expected
   labels
7. Test combinators in `nix repl` —
   `mkGroup |> withAutoscaler |> withPDB` produces correct resource group

---

## Tricky Parts Summary

| What | Where | Why it's tricky |
|------|-------|----------------|
| Infinite recursion | Phase 2 writeback | Lambda must never read `.output.*` — error message is unhelpful |
| Guard condition drift | Phase 4 label merge | Output read guards must exactly match target `mkIf` conditions; drift = crash |
| `mkIf false` behavior | Phase 2 | Suppressed targets don't exist in the attrset — no filtering needed or possible |
| `portName` vs `port` | Phase 1 interface | `mkServiceMonitor` needs string port name; keep `portName` as primary |
| Option ownership during migration | Phase 3 | Don't redeclare `monitoring.enabled` in capability module while `monitoring.nix` exists |
| Golden file diff scope | Phase 6 | Only metrics Services should change; diff against Phase 0 baseline |
| Assertion + echo completeness | Phase 5 | Grep for ALL `monitoring.targets` references including string interpolations |
| `//` shallow merge | Throughout | Use `lib.recursiveUpdate` or module system merging for nested attrsets |
| `recursiveUpdate` and lists | Phase 7 | Replaces lists, doesn't merge — fine now, document for future combinators |
| Metrics port duplication | Phase 4 | Port declared in capability AND container — unavoidable without `withMetrics` (deferred) |
