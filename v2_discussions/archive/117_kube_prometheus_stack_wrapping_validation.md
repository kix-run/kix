# 117: Wrapping kube-prometheus-stack — does Tier 2 helm cover the native rebuild's guarantees?

**Status:** Superseded (archived 2026-10). Q1 answered: the native stack is canonical and `kix/packages/kube-prometheus-stack` was deleted. Q2, Q3, and Q5 are in `ROADMAP.md § Open design questions` ("Prometheus stack: Helm bridge edges and native operator gaps"); Q4 is dropped, since the native operator's RBAC verbs are fixed in `prometheus-operator/operator.nix` and its single replica needs no PDB.
**Related:**
- `40_composite_packages.md` — the *decomposition* direction (predates Tier 2)
- `archive/68_prometheus_stack_kix_native.md` — just-shipped from-scratch rebuild (commit `d79478f`)
- `archive/86_helm_dag_reconstruction.md` + `archive/87_helm_integration_v2.md` — Tier 2 design (shipped)
- `96_netpol_autogeneration_blindspots.md` — helm called out as blindspot 1; Phase 2 was the fix
- `kube-prometheus-stack-fidelity/` — concrete fidelity gaps in the native rebuild
- `97_service_contract_primitives.md`, `101_monitoring_provider_landscape.md`, `110_alerts_as_graph_resources.md`

---

## Question

Phase 1a/1b/2/3 of the helm-wrapping capabilities just shipped. Strategic frame is committed: helm-sourced charts → **wrap**, don't fork. The just-landed `kix/packages/{prometheus-operator,prometheus,alertmanager,grafana,node-exporter,kube-state-metrics,prometheus-default-rules}` from-scratch rebuild is one expression of "kix guarantees on the monitoring stack"; another is wrapping the upstream `kube-prometheus-stack` chart (already exists at `kix/packages/kube-prometheus-stack/default.nix`).

**Does the wrap path preserve the same guarantees the rebuild buys?**

User's primary bar: **correct Merkle DAG representation**. Secondary: cross-package DI, especially the type-richness loss when typed kix deps (postgres, secrets, services) flatten into helm scalar values.

## Findings — Merkle DAG

Both paths terminate in the same `mkResource` (`k8s.nix:151+`), so content-addressing and `kix.dev/depends-on` stamping are identical. Question reduces to: does each wrapped resource arrive at `mkResource` with the right `requires` list?

### Wrap path's edges come from two sources

1. **Intra-chart inference** (`helm-dag.nix:68–408`) — nine reference patterns:
   - workload → ServiceAccount (`podSpec.serviceAccountName`)
   - workload → ConfigMap/Secret (volumes, projected, envFrom, env.valueFrom)
   - RoleBinding/ClusterRoleBinding → ServiceAccount (subjects)
   - Service → Workload (selector subset match against pod template labels)
   - HPA → target (scaleTargetRef)
   - PDB → workload (selector match)
   - Ingress → Service (default + rules backends)
   - HTTPRoute → Service (backendRefs)
   - ServiceMonitor → Service (selector against Service labels)
2. **Cross-package context plumbing** (`helm.nix:387–403`) — Phase 2 auto-collects context-carrying strings from each declared `dep.out.*` (top level only; nested values like `dep.out.byKind.Service.x.out.fqdn` need explicit `networkDeps`).

### Intra-chart edges kube-prometheus-stack uses that the inference path MISSES

1. **Operator-CR `spec.serviceAccountName`** (Prometheus, Alertmanager). `podSpecOf` only walks `template.spec`, not CR-level `spec`. Concrete: `kix/packages/prometheus/default.nix:692` writes this; chart does the equivalent at `templates/prometheus/prometheus.yaml`.
2. **CR → Secret refs** (`Prometheus.spec.additionalScrapeConfigs.{name,key}`, `Alertmanager.spec.configSecret`, `spec.web.tlsConfig.*.secret.name`, `spec.alerting.alertmanagers[].tlsConfig.*`). Native lines 568–581, 740.
3. **Mutating/ValidatingWebhookConfiguration → Service** (`webhooks[].clientConfig.service.name`).
4. **Runtime-selected resources** (PrometheusRule/ServiceMonitor/PodMonitor picked up by the operator at runtime via label selector). **Both paths have this blindspot** — relies on consumer CRs `requires`-ing the CRD ref so the chain pulls in the operator workload transitively.
5. **Cross-namespace Service references baked into chart values** (e.g. `kubeletService = kube-system/kubelet`).

(1)–(3) are fixable with two new patterns in `helm-dag.nix`:
- "any `spec.serviceAccountName` field at any depth"
- "shape `{ name, key }` where `name` matches a chart `Secret`/`ConfigMap`"

(4) structural — both paths.
(5) per-package; declare with `extraEdges` or `networkDeps`.

User pre-pause inclination: extend `helm-dag.nix` (option 1) **mixed with** per-package `extraEdges` (option 2). Both in scope.

## Findings — DI / type-richness loss

Helm values are scalars. Kix DI passes typed objects whose `out.*` strings carry Nix string context. The wrap is an **adapter**: typed DI on the wrapper signature, scalar values at the chart-values boundary.

### The lossy pipeline

1. `builtins.toJSON values` → `pkgs.writeText "helm-values.json"` (`helm.nix:180`). **Context survives** — `toFile` preserves it as references.
2. `helm template` runs as external process (`helm.nix:201–206`). **Pure bytes; Nix has zero visibility.**
3. `builtins.readFile templateDrv` (`helm.nix:494`). **`readFile` strips context.**

Phase 2 reconstructs context post-hoc by **substring-matching** `dep.out.*` values against the rendered text and re-attaching context where matches show up.

### Categories of dep flowing through this pipeline

| Case | Example | Phase 2 recovers? | Notes |
|---|---|---|---|
| **A. Identifier passed verbatim** | `externalDatabase.host = postgres.out.host` | ✓ | Common case |
| **B. Identifier transformed by sprig** | `{{ .Values.x \| b64enc }}`, `sha256sum`, `printf` | ✗ | **Silent edge loss.** No diagnostic today. |
| **C. Identifier rendered into ConfigMap/Secret data** | host string written into a ConfigMap value | ✓ | Substring scan still finds it |
| **D. Cross-namespace Secret ref** | `existingSecret = otherNs.secret.out.name` | ✓ Merkle / ✗ kix policy | `_kix.namespace` marker stripped in helm round-trip; cross-ns validator can't fire |
| **E. Predictably-named chart resource consumed by kix** | `chart.out.byKind.Secret.foo.out.name` | ✓ | Phase 1a auto-publishes byKind |
| **F. Templated chart-internal name** | `{{ printf "%s-%s" .Release.Name .Chart.Name }}` | ✓ if wrapper does discovery | Wrapper has to expose `out.alertmanagerConfigSecret = chart.out.byKind.Secret."${releaseName}-..."` |
| **G. Implicit-feature dep** | `serviceMonitor.enabled = true` requires prometheus-operator in cluster | ✗ | Chart values don't reference any kix object → no `dep.out.*` to scan. Must declare via wrapper's `deps` arg. |

### Tools we have

- Phase 2 substring scan (covers A, C, D-Merkle, E, F)
- Explicit `deps = [ ... ]` arg (G partial — declares but doesn't validate)
- `out.byKind` (E, F)

### Tools we're missing

- **Diagnostic for declared-but-unscanned `deps`.** If a `dep` produces zero substring matches, warn. Catches both forgotten thread-through (G) and sprig-transformed identifiers (B). ~15 LoC in `helm.nix` after the substring scan. **Highest-leverage fix.**
- **`crossNamespaceRefs = [ { secret, namespace } ]`** explicit declaration on `importChart`. Sidesteps the helm round-trip for kix-side cross-ns validation.
- **`requiresCapabilities = [ "monitoring" ... ]`** on the wrapper + scorecard rule. Catches G mistakes.

## Concrete loss audit — `kix/packages/prometheus/default.nix` → wrap

Reading the just-landed native package side-by-side with what a `prometheus.enabled = true` slice of `kube-prometheus-stack` would deliver:

### Survives

- CRD builders (`prometheus.out.mkServiceMonitor` etc.) — same shape via Phase 3 auto-derivation OR existing `mkCRDRef` shim (`kube-prometheus-stack/default.nix:281–315`).
- `extraSpec` ≡ chart's `prometheus.prometheusSpec` passthrough.
- Wrapper-level typed options (`monitoring.prometheus.retention :: str`) — wrapper translates to chart values inside `build`.
- Cross-package `alerting = [ alertmanager.out.fqdn ]` — Phase 2 recovers.

### Degrades (recoverable with the helm-dag.nix extensions above)

- **CR → ServiceAccount edge** (line 692). Missed by helm-dag.nix.
- **CR → additionalScrapeConfigs Secret edge** (lines 568–581, 740). Same fix.
- **External-Secret cross-package mode** (lines 559–581). Phase 2 recovers when literal name passes verbatim; fails on sprig.
- **Custom `out.serviceUrl`** (line 940). Wrap exposes `out.url { port = 9090; }`. One-line consumer migration.

### Dies — no current recovery

1. **RBAC DSL** (lines 628–672). `grant/core/group/watch/allow` + `mkClusterRoleSet` produces a 30-line reviewable verb set. Chart RBAC is opaque YAML in `templates/prometheus/clusterrole.yaml`. Can't widen/narrow without forking.
2. **Typed CR builder `mkPrometheus scope { ... }`** (line 685). Chart authors the CR; you nudge via values. Lose: per-field validation, ability to insert kix-managed references at arbitrary spec paths cleanly.
3. **Per-key Secret validation** (`scope.mkSecret { keys = [ ... ]; }` at lines 737–763). Chart Secrets are opaque.
4. **Cross-namespace `_kix.namespace` validation.** Stripped in helm round-trip.
5. **Granular per-component `meta` (lifecycle / provides / aliases)** (lines 23–38). Wrap declares one `meta` for the bundle. A consumer asking only for `prometheusServer` (TSDB) gets the whole stack.

### What the wrap GAINS over the rebuild

Per `kube-prometheus-stack-fidelity/prometheus-operator.md`, the native rebuild silently dropped:

- Admission webhooks (Mutating/Validating + cert-manager Issuer/Certificate path + patch Job). `enableAdmissionWebhook` is a dead toggle today.
- NetworkPolicy / CiliumNetworkPolicy.
- PDB, VPA, aggregate ClusterRoles (view/edit aggregation for monitoring CRDs).
- Operator ClusterRole verbs: `pods/delete`, `discovery.k8s.io/endpointslices`, `*/status`, `events.k8s.io` — load-bearing for actual operator function.
- Free chart upgrades.

## Trade summary

| Axis | Native rebuild | Wrap |
|---|---|---|
| Merkle DAG (resources both produce) | tight, minimal | structurally equivalent if `helm-dag.nix` extended (3 patterns) |
| Intra-chart edges from CR-shaped resources | n/a | weaker today, fixable |
| Cross-package edges | direct via context | Phase 2 substring recovery; lossy on sprig transforms |
| RBAC reviewability | DSL, 30 lines | opaque chart YAML |
| Typed CR authoring | yes (`mkPrometheus scope { ... }`) | chart authors CR; values-only |
| Per-key Secret validation | yes | no |
| Cross-ns `_kix.namespace` policy | yes | no (helm round-trip strips marker) |
| Granular lifecycle / provides per component | yes | bundle-level only |
| Chart feature parity | as-rebuilt; documented gaps | full upstream |
| Upgrade cost | reimplement deltas | bump version + values |

## Open questions

### Q1 — strategic call (paused here)

Do guarantees (1)–(5) under "Dies" matter enough on operator-CR-shaped packages (Prometheus, Alertmanager, AlertmanagerConfig, ServiceMonitor) to justify keeping the rebuild as the canonical expression and using the wrap only as fallback?

Or framed inversely: are RBAC reviewability + cross-ns `_kix.namespace` validation things we accept losing across the board to commit fully to wrapping?

### Q2 — diagnostic gap

Should we ship the "declared-but-unscanned `deps`" diagnostic as a precondition for wrapping more charts? Only tool that catches sprig-transformed identifiers + forgotten thread-throughs. ~15 LoC.

### Q3 — helm-dag.nix extensions

Two patterns close most operator-CR gaps:
- "any `spec.serviceAccountName` field at any depth, refs a `ServiceAccount` resource by name"
- "shape `{ name, key }` (or `{ name }`) where `name` resolves to a chart `Secret`/`ConfigMap`"

Risk: false-positive edges if a CR field happens to share the key name without being a real reference. Mitigation: gate on the referenced resource actually existing in the chart (already how the existing patterns work).

### Q4 — `crossNamespaceRefs` shape

Only worth designing if kube-prometheus-stack actually has cross-ns Secret refs in real cluster configs. **TODO before designing:** audit. Defer.

### Q5 — RBAC reviewability for chart-shipped roles

Open: any way to surface chart-shipped RBAC into the kix scorecard / diagnostics layer so reviewability isn't completely lost? Maybe build-time "extract RBAC from chart, render as RBAC DSL summary, attach as derived `meta.rbacSummary`" — purely informational, not authoring. Out of scope for first pass.

## Proposed next concrete steps (in order of "most informative")

1. **Audit kube-prometheus-stack templates for sprig transforms on user-controllable values** (read-only). If small → wrap survives the type-loss objection. If large → real exposure. Search keys: `b64enc`, `sha256sum`, `replace`, `printf`, `tpl`. Scope: `charts-to-migrate/helm-charts/charts/kube-prometheus-stack/templates/`.
2. **Ship the declared-but-unscanned `deps` diagnostic.** Smallest, generic, catches both B + G.
3. **Extend `helm-dag.nix` with the two new patterns** (`spec.serviceAccountName` at any depth, `{name, key}` Secret/ConfigMap refs).
4. **Build a wrap-mode kube-prometheus-stack alongside the rebuild, compare DAGs.** Run both through `nix-store -q --tree` rooted at the Activation CR; diff edge sets. Compare with cluster-dump diff. **This is the validation step** the strategic call (Q1) needs.
5. **Strategic call (Q1)** — informed by the result of (4).

## State of conversation when paused

User wanted to validate the just-shipped Tier 2 capabilities against the from-scratch rebuild, with **Merkle DAG correctness as the primary bar** and DI type-richness as the secondary concern. Mode was interactive.

Conversation walked Q1 (Merkle DAG scope) → Q2 (DI lossy pipeline + categories A–G) → loss audit on `prometheus/default.nix`. Last open question posed to user (this doc's Q1 above): *"do (1)–(5) under 'Dies' matter enough on operator-CR packages to keep the rebuild canonical?"*

Pre-pause user inclination: option (1) "extend helm-dag.nix" + (2) "per-package extraEdges" mixed. So the lib-side fix is in scope; the strategic question is whether to wrap-replace the rebuild or keep both.

When resuming: pick a concrete next step from the list above. Step (1) is read-only and gives the most signal cheapest — would inform Q1 directly.
