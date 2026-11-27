# 115: Pod-spec hardening as a derivation pass

**Status:** Draft (RFC + design sketch)
**Relevance:** Active — concrete driver, no implementation yet
**Related:** `29_compiler-design.md` §4 (derivation pass), §6 (platform-engineer persona); `100_package_dsl_ergonomics_survey.md`; `archive/39_di_driven_defaults_design.md`; `96_netpol_autogeneration_blindspots.md` (Helm opacity precedent); `105_ludo_homelab_operational_readiness.md` + `110_alerts_as_graph_resources.md` (cluster-profile knob shape)
**Supersedes:** none

## Problem

Every Helm chart with a "production-ready" reputation injects the same pod-spec hardening defaults on every workload it ships:

- `securityContext.seccompProfile.type = RuntimeDefault`
- `securityContext.allowPrivilegeEscalation = false`
- `securityContext.capabilities.drop = [ "ALL" ]`
- `securityContext.readOnlyRootFilesystem = true`
- `securityContext.runAsNonRoot = true` + `runAsUser` / `runAsGroup`
- `automountServiceAccountToken = false` (where unused)

In kix today this is the package author's responsibility. We just paid the cost twice in a row — `infisical-operator` and `dns-exporter` each re-derived the same `securityContext` block by hand. Every new package will pay it again, and any one package missing a field creates drift the cluster operator (SRE, §9) has no way to catch except by reading manifests.

This is the wrong persona doing the wrong work. Hardening is an operational baseline, not a service contract — the SRE persona owns it (§9), the platform team enforces it across the fleet (§9), the package author should not be re-typing it for every workload they ship.

## Proposal

A cluster-level **pod hardening profile** that the kix evaluator merges into every workload at build time, materialized through the same machinery that already merges netpol-derived resources into workloads pre-`toFile`.

```nix
# In the cluster definition:
{
  cluster.podHardening.profile = "restricted";  # | "baseline" | null
}
```

Profile vocabulary tracks **PodSecurityStandards** verbatim (§8 — standard K8s vocab over invented). `baseline` and `restricted` mean what PSA says they mean. There is no kix-specific profile name and no "subset of restricted" — if we ship `restricted`, we ship every field PSA defines for it.

Two mechanical entry points, mirroring the existing kix derivation patterns:

1. **Native workloads** — `scope.mkDeployment` / `mkStatefulSet` / `mkDaemonSet` merge profile fields into the workload args **pre-`toFile`**, at the same interception point `netpol.buildWorkloadCnps` already uses. The hardened spec is what gets sealed into the workload's store-path identity.
2. **Helm-imported workloads** — `importChart` walks raw JSON workload resources **pre-wrap**, at the same interception point `helm-dag.nix` already uses to stamp `requires` edges. Profile fields merged into `spec.template.spec` before `mkResource` seals the manifest.

Both paths feed the **same scorecard rule** (`architecture.hardeningWeakened`) that compares the rendered spec against the active profile and fires per-field when an author override weakens the baseline.

### Where it slots in `29_compiler-design.md`

- **§4 (derivation pass):** this is a derivation pass in the §4 sense — operator-declared cluster config materializes into resources at build time, no per-package work, no runtime detection. It composes with the existing derivation passes (netpol, scorecard, capability fingerprints) rather than replacing or layering above them.
- **§6 (platform-engineer persona):** this is the persona's API surface for security baseline. `cluster.podHardening.profile` is a single knob set once per cluster; everything downstream is mechanical.

## Why a derivation pass and not the alternatives

The choice was between five candidate enforcement slots:

| Option | Verdict | Reason |
|---|---|---|
| **A.** Pre-`toFile` mutation in `scope.mk*` | **Chosen (mechanism)** | Hardened spec carries into the workload's store path. Identity contract preserved. Same shape as `netpol.buildWorkloadCnps`. |
| **B.** Post-fixpoint pass over `allPartResources` | Rejected | Rewrites already-built resources → store-path churn. Breaks §2 (store as IR). |
| **C.** Cluster module that defaults `scope.mk*` args | **Chosen (surface)** | Operator-side knob, plumbing already exists for `clusterConfig`. §13 (wiring > module > meta) — but this is operator-baseline, not author wiring, so module is the right tier. A is *how* C is wired. |
| **D.** Pure DSL primitive (`kix.harden`) | Rejected | Opt-in defeats the goal. §11 (automation over brevity, safety net wins). §13 — author isn't the right persona. |
| **E.** Scorecard rule only | Rejected as standalone, **kept as part of the design** | Pure detection violates §6 (every compile-time failure must fail at compile-time *with action*). The rule is necessary as the §6 diagnostic surface for Q3a-(ii) overrides — but it does not stand alone. |

**Rejected outside the table:** runtime admission (Kyverno, OPA, PSA admission controller). §4 forbids exactly this — if the type system can rule it out, no admission webhook should need to. PSA *vocabulary* is K8s-standard and we adopt it; PSA *enforcement at admission* is the runtime detection §4 says we obviate.

## Design

### Cluster surface

```nix
# kix/lib/modules.nix — new option
options.cluster.podHardening = {
  profile = mkOption {
    type = types.nullOr (types.enum [ "baseline" "restricted" ]);
    default = null;
    description = ''
      Apply the named PodSecurityStandards profile to every workload.
      `null` disables hardening (no merge, no scorecard rule).
    '';
  };
};
```

No fine-grained per-field knobs in v1. `cluster.podHardening = { profile = "restricted"; readOnlyRootFilesystem = false; }` is **not** an API we offer — it's the §8 violation we're avoiding. Operators who need a different shape author a custom profile object and we revisit the API once we've seen the second concrete need (§14).

### Author override semantics

Author values **win silently at the merge layer**, scorecard catches the weakening:

- Cluster module says `profile = "restricted"`, package author writes `securityContext.readOnlyRootFilesystem = false` on a workload that needs writable scratch space.
- The merge is `recursiveUpdate clusterDefaults authorSpec` — author wins per-field.
- The `architecture.hardeningWeakened` scorecard rule fires on that workload, naming the field, the active profile, the value PSA wants and the value the author set, and pointing at the likely fix (e.g. "add an `emptyDir` mount for the writable path").

This is the §7 escape hatch (always available, dropping to raw K8s never blocked) paired with the §6 actionable diagnostic. The author is not blocked, the operator is not blind.

`workload.out` does **not** expose hardening state. `out` is the surface downstream resources wire against (selectors, names, fqdns, ports). Nobody constructs a resource by reading another workload's hardening profile; the scorecard reads the rendered spec directly. Adding `out.hardened` would be §14.

### Scope of v1: PSA `restricted`, the whole thing

Both PSA tiers ship with their full field set. We are designing the API; there is no in-production fleet to roll out gradually, so partial subsets of `restricted` would be inventing a kix-specific vocabulary (§8 violation).

| Field | Notes |
|---|---|
| `seccompProfile.type = RuntimeDefault` | Universally safe. |
| `allowPrivilegeEscalation = false` | Universally safe. |
| `capabilities.drop = [ "ALL" ]` | Universally safe; explicit `add` opts capabilities back in. |
| `automountServiceAccountToken` | Set `false` *unless* the workload's SA is the subject of a Role/ClusterRoleBinding in the instance closure. The SA→Binding walk already lives in `netpol.processInstance` (`boundSAKeys`); we extract it into a shared helper. |
| `readOnlyRootFilesystem = true` | Many images write to `/tmp`, `/var/run`. Override + scorecard. |
| `runAsNonRoot = true` + `runAsUser` / `runAsGroup` | Requires the image to ship a non-root user. Documented as part of what `restricted` means; if/when we build images via `dockerTools` (doc 26), the non-root user is something the kix-built image just *has*. |

**Explicitly out of scope for this doc:**

- `podAntiAffinity` for replicated workloads — not part of PSA. Wants `cluster.hardware.topologyKey` (§9 operator data we don't yet model fleet-wide). Belongs in a follow-up scheduling-policy doc.
- Default `resources.requests` / `resources.limits` — not part of PSA. Wants a LimitRange story or hooks into doc 100 `boundedResources`. Separate doc.

These two were what the trigger conversation called "the helm-chart hardening defaults." They *are* hardening, but they are *not* PSA, and bundling them here would conflate two design problems. Linking forward as future work.

### Implementation sketch

New file `kix/lib/hardening.nix`, two entry points, mirroring `helm-dag.nix` + `netpol.nix`:

```nix
# Called from scope.mkDeployment / mkStatefulSet / mkDaemonSet,
# pre-`builtins.toFile`, at the same interception point as
# `netpol.buildWorkloadCnps`. Merges profile fields into the
# author-provided spec; author wins per-field.
mergeIntoWorkloadInput =
  { profile, workloadInput, saIsBound }: …

# Called from `importChart`, raw-JSON pass, pre-wrap — same
# interception point as `helm-dag.nix`. Walks chart resources
# matching workloadKinds, merges profile fields into
# `spec.template.spec`. Chart values win per-field.
mergeIntoChartWorkloads =
  { profile, rawResources, saBindingIndex }: …
```

The scorecard rule lives in `kix/lib/rules/architecture.nix` next to `capabilityOwnership`:

```nix
# Reads rendered spec, compares against the active profile.
# Helm-vs-native is invisible to the rule — it sees workloads.
architecture.hardeningWeakened = { … };
```

Plumbing changes:

- `eval/scope.nix`: thread `clusterConfig.podHardening` into `mkDeployment` / `mkStatefulSet` / `mkDaemonSet` (the channel exists; `clusterConfig` already flows here for netpol).
- `eval/cluster.nix`: pass profile into `importChart` raw-JSON pass. Uses the existing helm-dag.nix machinery, adds one more transform.
- The SA→Binding walk in `netpol.processInstance` becomes a shared helper used by both netpol and the hardening pass for `automountServiceAccountToken` derivation.

Estimated surface: ~150 lines in `hardening.nix`, ~30 lines of plumbing, ~80 lines for the scorecard rule.

## Alternatives considered

- **`meta.hardening` per package.** Rejected by §13 — `meta` is for kix-concerns hints that drive auto-wiring (statefulness, importance, consistency class), not for plumbing config. Hardening is operator-tier baseline, not author intent.
- **Runtime admission (PSA admission, Kyverno, OPA).** Rejected by §4. PSA *vocabulary* is adopted; PSA *admission* is the runtime detection we obviate.
- **DI capability (`hardening-provider`) auto-discovered like the netpol enforcer.** Rejected — there is no implementation choice for the operator to make. PSA defines the field set; the merge is mechanical. Capability/DI buys us nothing over a module.
- **Per-package `kix.harden` opt-in pipe.** Rejected by §11 (opt-in defeats the safety goal) and §13 (wrong persona).
- **Bootstrap-then-enforce sequencing** (ship the scorecard rule first, derive merge later from exemption data). Rejected — that's production-software thinking. We own the API; we design the right shape now.

## Open questions

1. **Helm chart authors that hand-roll `securityContext`.** Many charts already ship a `restricted`-shaped securityContext, sometimes weaker on one field. Author-wins precedence means the chart's value beats the cluster default. Scorecard fires. Is that the right call for charts, or do we want the chart's values to be the *floor* (cluster strengthens, chart never weakens)? Native packages have this same question but the answer feels different — chart authors are not "the package author" in the §9 sense.

2. **`runAsUser` numeric value.** PSA `restricted` requires `runAsNonRoot = true` but does not pin a specific UID. Do we pick a kix-wide default UID (e.g. `65532`, the distroless nonroot UID) when the workload doesn't specify one, or leave it unset and let the image's own non-root user apply? Latter is more compatible; former is more deterministic.

3. **Init containers and ephemeral containers.** PSA applies to all container types in the pod spec. The merge needs to cover `spec.template.spec.initContainers[*]` and `spec.template.spec.containers[*]` symmetrically. Confirming the helper enumerates both.

4. **Pod-level vs container-level securityContext.** PSA partly distinguishes pod-level and container-level fields (`runAsNonRoot` is both). The merge needs to set fields at the K8s-correct level, not just dump everything at pod level. Belongs in the implementation, but flagging as a sharp edge.

5. **Interaction with `meta.exposure` / `kix.expose`** (doc 107) — does an exposed workload have different hardening needs (e.g. ingress controllers genuinely need `NET_BIND_SERVICE`)? Probably handled by the override + scorecard rule, but worth confirming the diagnostic message helps the author understand they're hitting an expected case rather than a bug.

## Future work (out of scope, linked from here)

- **Anti-affinity for replicated workloads** — wants `cluster.hardware.topologyKey`, fleet-wide topology. Separate doc.
- **Default resource requests/limits** — wants a LimitRange story or hooks into doc 100 `boundedResources`. Separate doc.
- **Image vertical integration** (doc 26) absorbs the `runAsNonRoot` coordination cost — kix-built images ship a non-root user by construction.
- **Backup/restore + monitoring + alerting profiles** — same `cluster.<concern>.profile = "..."` shape this doc establishes. Worth converging vocabulary across doc 105 (`cluster.alerts.profile`), doc 108 (`cluster.backup`), and this doc once a second concrete example lands.
