# 100: Package DSL Ergonomics Survey

**Status:** Brainstorm
**Related:** `29_compiler-design.md`, `31_port_fanout_dsl.md`, `32_volume_mount_dsl.md`, `35_crd_derived_rbac_webhooks.md`, `65_passthrough_instances.md`, `92_declarative_network_policy_intents.md`, `96_netpol_autogeneration_blindspots.md`, `97_service_contract_primitives.md`

Cross-cutting inventory of pain points encountered writing `kix/packages/*`, each mapped to what `kix/lib/` offers today and a proposed hook. Raw findings came from an audit of ~12 representative packages (ingress-nginx, velero, stackgres-operator, cert-manager, coredns, immich, n8n, prometheus, valkey, harbor, openebs, python-app, cilium).

For each item: **source** (package:line) → **kix/lib status** (file + symbol or "none") → **classification** (abstraction vs code-saver) → **proposed hook** (mechanism, not just file).

Items are ordered by prevalence × severity. "Abstraction" means we think the K8s shape itself is wrong and kix should model it differently. "Code-saver" means the shape is fine, but authors shouldn't have to type it.

---

## A. Selector/label coherence

### A1. Workload ↔ Service selector drift
**Source:** `ingress-nginx:202-210,409,587`, `velero:26-29`, `openebs/mayastor.nix:87-90`, `valkey`, `coredns` (widespread).
Labels declared in a `let`, then manually threaded into `spec.selector.matchLabels`, `spec.template.metadata.labels`, and `Service.spec.selector`. In `ingress-nginx:586-587` a comment explains the let-binding exists specifically to sidestep an evaluation cycle if the Service read `self.deployment.out.selector`.

**kix/lib status:** Partial.
- `scope.selectorLabels` (`eval/scope.nix:86`) already emits the standard label set.
- `kix.service.fromWorkload` (`compose.nix:79`) exists and *does* consume the workload's selector — most packages just don't use it. When they do (`coredns:356`), it works.
- The cycle ingress-nginx hit is real: reading `self.deployment.out.selector` inside the same scope can trigger it when the Service is declared before the workload in `self`.

**Class:** **Abstraction (small)**. Not a K8s rethink, but the cycle is a library defect — the DSL is pushing users to copy literals. Fixing it once removes the strongest argument for hand-rolled labels.

**Proposed hook:** Two-layer.
1. Break the cycle: have `mkDeployment/StatefulSet/DaemonSet` (`eval/scope.nix:1637-1639`) compute `out.selector` from the declared `spec.template.metadata.labels` using a **thunk that doesn't force the full resource**. Today `out.selector` likely reads through the wrapped resource fixpoint; the fix is to make selector resolution a separate lazy value keyed off the raw labels arg, forced without going through `mkResource`'s context attachment.
2. Make `kix.service.fromWorkload` the one-true-path. Add an `architecture.selectorCoherence` scorecard rule (`rules/architecture.nix`) that flags Services whose `spec.selector` is a literal attrset instead of sourced from a workload — same mechanism as `capabilityOwnership`, data-only rule.

**Follow-up findings (2026-04-15, from ludo flake-check sweep):** the scorecard rule *did* ship (`rules/architecture.nix:227-254`) but the one-true-path didn't, so the rule now fires noisily against cases it can't resolve:

1. **Helm-imported Services.** `helm-dag.nix:270-282` infers Service→Workload edges by label subset match (used for ordering/requires), but never rewrites the Service's `spec.selector` *values* to carry the workload's store-path context. The rule checks `builtins.getContext v`, so DAG edges alone don't satisfy it. The infrastructure is present — one pass inside `importChart` mapping matched Service selectors to `lib.addContextFrom workload.out.name v` would clear the entire Tier 2 cohort (cilium-envoy, valkey, loki×4, ingress-nginx×2, promtail-metrics) in one go. Until it ships, the rule is structurally unsatisfiable for helm Services. Alternative: gate the rule on `!packageMeta.isHelm`, but that loses detection on hand-written selectors inside `patchResources`.
2. **Operator-reconciled workloads.** `alertmanager/default.nix:119-158` and `prometheus/default.nix` emit a CR (`Alertmanager`, `Prometheus`) that the prometheus-operator reconciles into a StatefulSet *outside* kix ownership. The package's own Service must match the operator's hard-coded label convention (`app.kubernetes.io/name=<kind>`, `app.kubernetes.io/instance=<name>`). There is no kix-owned workload to feed into `kix.service.fromWorkload`. Proposed hook: `kix.service.fromControllerCR { controller = self.alertmanager; matchLabels = {...}; }` that stamps selector values with the *CR's* store-path context. The DAG edge anchors to the CR (which is real) instead of the phantom operator-generated StatefulSet. Same ergonomic shape as `fromWorkload`; different context source.

### A2. Label hierarchy hand-composition
**Source:** `ingress-nginx:202-217` (three overlapping label sets: `selectorLabels`, `commonLabels`, `clusterScopedLabels`), `stackgres-operator:34-42`.

**kix/lib status:** `scope.selectorLabels` exists; there is no `scope.commonLabels` / `scope.clusterLabels` layered equivalent. Packages reinvent the stacking.

**Class:** **Code-saver.** The hierarchy itself (selector ⊂ common ⊂ cluster-scoped) is standard K8s convention.

**Proposed hook:** Extend the scope builder in `eval/scope.nix` to expose `scope.labels.{selector, common, clusterScoped}` as lazy attrsets built from the same source as `selectorLabels`. All three compose from one input: the package's `meta` + instance name. No new concept, just pre-baked stacks. `mkResource` can also apply `labels.common` by default when no `labels` arg is passed (opt-out via `labels = { ... };`).

---

## B. RBAC trios

### B1. ServiceAccount + Role/ClusterRole + RoleBinding as one unit
**Source:** All 54 packages with workloads. `ingress-nginx:365-373,219-306`, `velero:239-304`, `stackgres-operator:334-582`.
Same three-resource shape, same `subjects = [{ kind = "ServiceAccount"; name = self.sa.out.name; namespace = scope.namespaceName; }]` block every time.

**kix/lib status:** `rbac.nix` has a pipe DSL for **rules**, not for the trio. Rules can be composed elegantly; the trio is still three calls.

**Class:** **Abstraction.** The "permissioned identity" is a single concept that K8s splits across three resources for historical reasons. This is exactly the kind of K8s-shape-is-wrong case that belongs in kix.

**Proposed hook:** New `scope.mkIdentity` (`eval/scope.nix`, alongside `mkDeployment`) returning `{ serviceAccount, role/clusterRole, binding, out = { saRef, mountOn = workload: …, … } }`. Mechanism:
- Input: `{ name?, rules, clusterScoped ? false, bindTo ? self }`.
- Output attrset is a **composite resource group**: `_type = "k8s-resource-group"` with `collectTypedAttrs` descending into it (extend `eval/helpers.nix:collectTypedAttrs` to recognize groups — already stops at `_type`, just add the group kind).
- `out.mountOn` produces a workload mutator that sets `spec.template.spec.serviceAccountName` and injects the SA→workload store-path edge so netpol's SA walk (`netpol.nix:processInstance`) keeps working without code changes.
- Workloads that do not call `mountOn` continue to use the default SA — no implicit binding.

### B2. RBAC rule verbosity
**Source:** `stackgres-operator:334-582` (248 lines of rules), `cert-manager/controller.nix:67-195`. cert-manager invented a local `grant` helper; stackgres did not.

**kix/lib status:** `rbac.nix` pipe DSL (`group`, `watch`, `reconcile`, `allow`, `restrictTo`, `sub`) — *already solves this*, but underused.

**Class:** **Code-saver** (already solved, adoption problem).

**Proposed hook:** Non-code: migrate the three worst offenders (stackgres-operator, cert-manager, prometheus-operator) to `rbac.nix` DSL in a dedicated PR and add a scorecard rule `architecture.rbacUsesDsl` that warns when a rule list has >N (say 5) raw entries. The rule is a smell detector, not a hard fail.

### B3. CRD-derived rules and webhooks
**Source:** `stackgres-operator:175-223,826-862`, `cert-manager`, `prometheus-operator`.

**kix/lib status:** In-design — doc 35.

**Class:** **Abstraction** (confirmed). Worth re-evaluating scope: doc 35 today focuses on RBAC + webhooks from CRDs, but the `mkValidatingWebhook` boilerplate is independent of CRDs (it's webhook-from-service) and could be lifted first as its own helper in `crd.nix`.

**Proposed hook:** Re-scope doc 35 into two hooks: (a) `scope.mkWebhookService` (new in `eval/scope.nix`) — takes a Service + a list of `{ kind, path, operations }` and emits both the Service and the `{Validating,Mutating}WebhookConfiguration`; (b) doc 35's CRD-side derivation becomes a thin wrapper that fills `kind/path/operations` from `mkCRD` outputs. This unblocks ingress-nginx and cert-manager (which aren't CRD-driven) right away.

---

## C. Service wiring

### C1. Port duplication across containerPort / servicePort / probe
**Source:** `ingress-nginx:465-481,588-602`, `velero:414-420,346-352`.

**kix/lib status:** In-design — doc 31 (port fanout DSL).

**Class:** **Abstraction** (confirmed). Direction *not* yet decided — three shapes considered, exploration below.

**Shapes considered:**

1. **`workload.out.ports`** (auto-derived from `containers[*].ports`). Cheapest; no new concept. Breaks on: multi-workload Service (ambiguous — which workload's `out.ports`?), leaks every container port as "exposed" (violates opt-in), introduces magic on the workload resource.
2. **Doc 31 registry** (port declared at package scope; workload + service + probe all subscribe). Handles multi-workload, cross-package, and opt-in naturally. Cost: a new registry concept and a new primitive.
3. **Ports as explicit values** (author declares plain structured values, passes them where needed — no registry, no magic on `out`). Example:
   ```nix
   let http = { name = "http"; number = 80; protocol = "TCP"; }; in {
     deployment = scope.mkDeployment {
       spec.template.spec.containers = [{
         ports = kix.ports.toContainer [ http ];
         livenessProbe.httpGet.port = http.number;
       }];
     };
     service = kix.service.fromWorkload self.deployment { expose = [ http ]; };
   }
   ```
   Multi-workload Services take the port value directly. Opt-in is enforced by construction (author chooses what to pass to `expose`). Cross-package works because the package exports its port values as public API (`pkgA.ports.metrics`). Rename is attrset override.

**Constraints discovered during exploration:**
- No magic on resources (`out.ports` may exist as a read-through, but must not be the source of truth).
- Multi-workload Services must **throw** on implicit derivation — ambiguity should be surfaced, not silently resolved.
- Exposure is **opt-in**. A workload declaring 5 ports must not auto-expose all 5 through the Service.
- Port renaming between layers (container `http` ↔ Service `web`) should be expressible without ceremony.

**Current lean:** Shape 3 (ports-as-values). Properties that earn it the nod:
- Nix-native — ports are just structured values; no new kix primitive beyond a thin `kix.ports.toContainer` adapter.
- Satisfies all four constraints by construction.
- Subsumes most of doc 31's use cases without a registry.
- Doc 31 gets re-scoped to "blessed port shape + fanout helpers that consume it" rather than a separate registry mechanism.

**Proposed hook:** Re-scope doc 31 around ports-as-values. Blessed shape (`{ name; number; protocol ? "TCP"; }`) lives in `kix/lib/ports.nix` (new) with adapters: `toContainer`, `toServicePort`, `toProbePort`. `kix.service.fromWorkload` gains an `expose` arg. Workloads may still publish `out.ports` as a read-through for ergonomic access inside the same scope, but the source of truth is the author's let-binding, not the container spec. Multi-workload `fromWorkload` throws unless `expose` is passed explicitly with the port values.

**Open questions (not resolved here):**
- Is `kix.ports.toContainer` worth adding, or is the shape close enough to the K8s container-port shape that a plain list works?
- Should `out.ports` exist at all, or does adding it re-introduce the ambiguity we wanted to avoid?
- Headless/stateful per-pod port addressing (ordinal-scoped) — probably covered by `out.podUrl`, confirm.
- Gateway-only / no-workload ports — ports-as-values handles trivially; worth a code sketch to confirm.
- Overlap with doc 31: does this *replace* the fanout DSL, or does fanout remain a higher-level helper layer on top of the blessed shape?

### C2. Service DNS hardcoding in env vars
**Source:** `prometheus:274`, `valkey:190-191`, `openebs/mayastor.nix:418,453`, `immich:229-244`.
`value = "http://${name}.${ns}.svc.cluster.local:9090"` or worse: `"http://$(MY_POD_NAME).${name}-etcd-headless.${ns}.svc.cluster.local:2379"`.

**kix/lib status:** `Service.out.fqdn` exists (architecture.md line 69). `scope.namespaceName` exists. No **URL builder**.

**Class:** **Code-saver.** K8s shape is fine.

**Proposed hook:** Add `out.url { scheme?, port? }` to the Service resource (defined wherever `out.fqdn` is derived — likely inside `kix.service.fromWorkload` / `mkResource`'s Service branch). For headless/stateful pod DNS (`pod-N.service.ns.svc.cluster.local`) add `out.podUrl { ordinal, scheme?, port? }` on StatefulSets. Env-from-URL: `kix.env.fromUrl "REDIS_URL" self.svc` in `compose.nix`. Cost is ~30 lines, benefit is every env block in the codebase.

### C3. ConfigMap/Secret volume triple-sync
**Source:** `coredns:269-343`, `ingress-nginx:522-543`.

**kix/lib status:** Solved — `kix.mount.{configMap,secret}` + `kix.withMounts` in `compose.nix:337-513`. Adoption problem.

**Class:** **Code-saver** (solved, adoption).

**Proposed hook:** Non-code. Migrate coredns and ingress-nginx; add scorecard rule `architecture.rawVolumeMounts` that flags a container with `volumeMounts` when the enclosing workload spec also has a `volumes` entry of kind `configMap|secret` — the `mount.*` path never produces the split shape. Data-only rule in `rules/architecture.nix`.

---

## D. Cross-package DI

### D1. `.out` contract is structural, not typed
**Deferred — see `interesting_thoughts/102_capability_contracts.md`.** Tight
coupling in wiring is currently a feature, not a bug: actively-wired paths
need to match, and an eval-time error on drift is acceptable. NixOS itself
doesn't use a nominal contract system. Revisit when a concrete
provider-swap driver appears.

### D2. Conditional monitoring wiring
**Source:** `immich:184,295-298`, `coredns:414-432`, every monitored package has `prometheus ? null` + `if prometheus != null then mkServiceMonitor else null`.

**kix/lib status:** `kix.monitor` in `compose.nix:822`; `modules/monitoring.nix` auto-wires when the stack is present. Partially solved.

**Class:** **Code-saver**, but the repetition indicates `kix.monitor` isn't ergonomic enough or isn't discoverable.

**Proposed hook:** Flip the default. Inside `scope.mkDeployment/StatefulSet/DaemonSet` detect containers with a port named `metrics` (convention) and auto-emit a ServiceMonitor via `forNamespace` into the monitoring capability's namespace — **only if** a monitoring capability is resolved in the cluster (same pattern as the netpol enforcer discovery in `netpol.nix`). Packages that want to opt out set `meta.monitoring = false`. Packages that need custom scrape config keep calling `kix.monitor` explicitly. Mechanism is identical to how netpol CNPs are spliced into the workload's `extraDeps` today; the monitoring resources become the mirror image.

---

## E. Optional resources & conditionals

### E1. `if cfg.x then mkResource else null` + `lib.optional (self.x != null)` in requires
**Source:** `velero:323-335,491-601`, `coredns:385-409`, `harbor`, `python-app`.

**kix/lib status:** None. The `self` collector (`eval/helpers.nix:collectTypedAttrs`) already tolerates `null` silently — so the "null-check in requires" pattern is *mostly* boilerplate on the requires side, not the build side.

**Class:** **Abstraction (small).** The K8s shape is fine; the authoring shape is wrong — optionality should be a first-class package feature, not a `null` sentinel.

**Proposed hook:** Add `scope.mkOptional cond resource` in `eval/scope.nix` that returns either the resource or a sentinel `{ _type = "k8s-absent"; }`. Extend `collectTypedAttrs` and `requires` handling in `eval/instance.nix` to treat `k8s-absent` as skip. Authors write `nodeAgent = scope.mkOptional config.nodeAgent.enabled (scope.mkDaemonSet {...});` and never touch `requires`. 30 lines.

### E2. `lib.optionalAttrs` scatter (141 occurrences / 29 files)
**Source:** Widespread.
`data = cfg.config // lib.optionalAttrs cfg.flag { snippet-annotations = "true"; }`.

**kix/lib status:** None — this is a Nix idiom, not a kix one.

**Class:** **Code-saver.** Probably not worth a DSL primitive; the real smell is that it clusters around fields that should live on `config` options with sensible defaults.

**Proposed hook:** Non-code. Not worth new API. Close as wontfix after a cleanup PR that pushes conditional values into option defaults (where they type-check and self-document). If we later find a cluster that truly is conditional output (not input), revisit.

---

## F. Image tag management

### F1. Multi-component version duplication
**Source:** `stackgres-operator:241-264` (same `1.18.6` tag for operator/restapi/adminui as three separate options), `cert-manager:49-85`.

**kix/lib status:** None. `meta.version` exists but is not linked to image tags.

**Class:** **Code-saver.** Arguably an abstraction if we want a *package-wide upgrade invariant* ("all components ship the same version"), which is worth thinking about for upgrade cascades (doc 67).

**Proposed hook:** Two layers.
1. Convention: `options.image.tag` at the package root. Sub-component options inherit by default: `options.operator.image.tag = mkOption { default = config.image.tag; }`. Pure Nix, no new kix primitive — but document as the kix-migration skill's canonical shape.
2. For real coupling (upgrade cascade): later, a `meta.componentVersions` assertion in `modules.nix` that fails eval if declared-same versions diverge. Defer until doc 67 drives it.

---

## G. Helper reinvention

### G1. Local helpers for webhook builders, selector-with-component, addNodePort
**Source:** `stackgres-operator:175-223` (`mkValidatingWebhook`, `mkMutatingWebhook`), `ingress-nginx:567-573` (`addNodePort`), `python-app/helpers.nix` (`selectorLabels component:`), `openebs:87-90`.

**kix/lib status:** None as shared. `compose.nix` is where this *should* live.

**Class:** **Code-saver** per helper, but the *reinvention pattern* itself is worth thinking about.

**Proposed hook:** Two moves.
1. Per helper: lift the webhook builder into `scope.mkWebhookService` (see B3); lift `selectorLabels component:` into `scope.selectorLabels { component ? null }` (amend `eval/scope.nix:86`); `addNodePort` is niche, leave it alone.
2. Meta-mechanism: the reinvention pattern is a **discoverability** problem. Add a `kix/lib/README.md` grouped by "if you are writing X, use Y" (workload → scope.mkDeployment; service → kix.service.fromWorkload; env from secret → …). This is the single highest-leverage doc change. The kix-migration skill file exists but is migration-focused, not authoring-focused.

### G2. `immich` TODO — auto-generated volume name collisions
**Source:** `immich:278`.

**kix/lib status:** `kix.withMounts` generates names; the TODO says duplicates can happen silently.

**Class:** **Code-saver / bugfix.**

**Proposed hook:** In `compose.nix:509` (`_injectMounts`), add an assertion that the generated name is not already present in `spec.template.spec.volumes`. Five-line fix; raises a diagnostic via the `80_structured_diagnostics` sidecar.

---

## H. Netpol wrapper consistency & intent acknowledgment
*(Added 2026-04-15 from ludo flake-check sweep.)*

### H1. `meta.isHelm` only auto-set by Tier 1 `kix.helmChart`
**Source:** `kix/lib/helm.nix:683` (Tier 1 auto-stamps `meta.isHelm = true`); no equivalent in `importChart` / `resources.mkParts` (Tier 2 path). `kix/lib/netpol.nix:576` emits *"Helm-wrapped package: intra-package network policies may be incomplete"* gated on `packageMeta.isHelm`.

Effect on ludo: homeassistant (Tier 1, `ludo/services.nix:70`) is the only package that trips the warning. cilium, loki, valkey, ingress-nginx, promtail, prometheus, alertmanager-stack all use Tier 2 and silently skip it — even though the netpol coverage concern applies identically. Inconsistent surface area.

**Class:** **Code-saver / bugfix** (warning either should fire on all helm-backed packages or none).

**Proposed hook:** Auto-stamp `meta.isHelm = true` inside `resources.mkParts` (or in the return value of `importChart`) so both tiers inherit it. Optionally, add a package-level opt-out `meta.network.helmCoverageReviewed = true` for packages that have had their netpol audited manually, so the warning becomes actionable instead of permanent background noise.

### H2. No way to acknowledge hostNetwork workloads
**Source:** `kix/lib/netpol.nix:423-425,570-574`. Warning fires for every hostNetwork workload ("CiliumNetworkPolicy has no effect"). Ludo hits this on cilium's DaemonSets (DS/cilium, DS/cilium-envoy, Deployment/cilium-operator) and on node-exporter — all intentional.

**kix/lib status:** None. `meta.network` already houses declarative intents (`meta.network.intents`, `meta.network.externalIngressEntities` consumed at `netpol.nix:558`) — natural extension point.

**Class:** **Code-saver** (needs a declarative off-switch, not a code rewrite).

**Proposed hook:** Add `meta.network.hostNetwork = { acknowledged = true; reason = "..."; }` to the meta schema. `netpol.nix:570` filters `hostNetworkWorkloads` against it before producing the warning. Package-level is fine for cilium and node-exporter (all their workloads are intentionally host-networked); if a package with mixed workloads appears, extend to per-workload annotation (`kix.dev/hostnetwork-acknowledged`) as a second pass. Keeping `reason` required makes the meta field self-documenting.

---

## Summary & next-step RFCs

Items warranting **bigger abstraction thinking** (should spawn or reshape an RFC):

| # | Finding | Status |
|---|---------|--------|
| B1 | `scope.mkIdentity` (SA+Role+Binding as one unit) | **New RFC** |
| B3 | `scope.mkWebhookService` — separable from doc 35 | Re-scope doc 35 |
| D1 | ~~Capability contracts~~ | **Deferred** → `interesting_thoughts/102` |
| E1 | `scope.mkOptional` + `k8s-absent` sentinel | **New RFC** (small) |
| A1 | Break `out.selector` cycle + scorecard rule | Fold into existing lib bugfix + `rules/architecture.nix` |
| C1 | Ports-as-values (blessed shape) — re-scopes doc 31 | **Re-scope doc 31** |
| D2 | Auto-monitoring wiring | **Design doc** → `102_auto_monitoring_wiring.md` |

Items that are **code-savers with a clear hook** (no RFC needed, just land them):

- A2 `scope.labels.{selector,common,clusterScoped}`
- C2 `Service.out.url` + `kix.env.fromUrl`
- G1 `scope.selectorLabels { component }`, webhook builder lift
- G2 volume-name collision assertion
- A1 follow-up: helm selector context-rewrite pass in `importChart` (clears Tier 2 `selectorCoherence` warnings en masse)
- A1 follow-up: `kix.service.fromControllerCR` for operator-reconciled CRs (alertmanager, prometheus)
- H1 auto-stamp `meta.isHelm` in `resources.mkParts`
- H2 `meta.network.hostNetwork.acknowledged`

**Adoption problems** (kix/lib already solves, packages don't use):

- B2 (rbac DSL) — migrate stackgres/cert-manager/prometheus-operator
- C3 (`kix.mount.*`) — migrate coredns/ingress-nginx

**Closable with no new API:**

- E2 `lib.optionalAttrs` — lint-only, if at all
- F1 image tag — convention, no primitive

---

## Open questions & decisions

1. **C1 overlap with doc 31.** *Direction shifted (2026-04-15).* After exploration, leaning away from `workload.out.ports` (too magical, fails opt-in) and away from a registry (too heavy) toward **ports-as-values** — authors declare structured port values and pass them explicitly. See C1 section for detail. Action: re-scope doc 31 around the blessed port shape before starting implementation; confirm whether `out.ports` should exist at all as a read-through.
2. **B1 vs doc 35.** Leaning toward `mkIdentity` first so doc 35 has a target to fill (`mkIdentity.rules` populated from CRD metadata). Not strongly held — revisit if doc 35 picks up momentum first.
3. **D1 typing surface.** *Deferred (2026-04-15)* to `interesting_thoughts/102_capability_contracts.md`. Tight coupling + eval error is the current contract and it's working. Revisit trigger documented in 102.
4. **Auto-monitoring (D2 hook).** *Deferred to dedicated brainstorm.* The "port named `metrics` → ServiceMonitor" shortcut is too provider-specific to design in isolation — ServiceMonitor assumes prometheus-operator, but VictoriaMetrics, OTel collectors, and annotation-scrape each want a different shape. Spawned as a separate brainstorm to survey the provider landscape before deciding auto-wiring behavior.
5. **`mkOptional` semantics.** *Decided.* Lazy (thunk-wrapped), mirroring `mkImport`. Cond=false skips evaluation of the resource builder entirely; cond=true evaluates and returns normally. Sentinel `{ _type = "k8s-absent"; }` for the `false` branch so `collectTypedAttrs` in `eval/helpers.nix` drops it.
