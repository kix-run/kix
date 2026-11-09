# 135: Where cross-resource validation lives, and what actually runs

**Status:** Draft, partly acted on (2026-09-08: options 1 and 3 below shipped as kixpkgs#72 and its follow-up PR; option 2 open)
**Related:** `29_compiler-design.md` §4.6 and §7.4, `archive/38_resource_type_tags.md` §8, `119_core_surface_audit.md`, `126_compiler_core_rewrite_plan.md`, `131_fact_kinds_and_operand_attribution.md`
**Trigger:** kixpkgs#69 added six VictoriaMetrics kinds to the `operatorManagedKinds` allowlist in `kix/checks.nix`. Adam asked whether that list should exist at all, and what the history of this code is.

Method: one read of all 13 checks against the constructors and the scorecard rules, one git history pass, and a break-it session on ludo-kind and the `cluster-victoria-metrics` fixture (2026-09-07). Every claim below was verified on commit 51e77a0.

## 1. What exists

Kix has three layers that can refuse a bad build.

| Layer | Where | When it runs | Sees |
|---|---|---|---|
| Constructor validators (`kix/lib/scope/validators.nix`) | inside `mkWorkload` and friends | every eval, throws | one resource, values with Nix provenance |
| Scorecard rules (`kix/lib/rules/`) | `buildCluster`, before serialisation | every eval when `scorecard.enable`, errors gate the build | instance or cluster resource sets, provenance intact |
| `validateManifestSet` (`kix/checks.nix`, 13 checks) | `checks."validate-cluster-<n>"` in `mkFlake` | only `nix flake check` | the whole finished manifest list, provenance stripped |

The three ask different questions. Constructors ask "is this one resource well formed". Rules ask "did this value come from somewhere" (provenance). The 13 checks ask "does the thing this name points at exist, and do these labels really match" (resolution). Section 4 shows both provenance and resolution are needed; neither implies the other.

## 2. History in five lines

- 2026-03-08: seven checks born inside `flake.nix`, the day raw manifests became attrsets. 2026-03-24: rewritten, grown to 13, allowlist for Prometheus and Alertmanager added the same day. Three documented catches in total (external-dns selector, valkey targetPort, harbor headless Service), all on 2026-03-24, none since.
- 2026-03-27: the kixpkgs CI workflow running `nix flake check` was deleted (f3f7c01). In this repo the 13 checks have run since only when a person types `nix flake check`. No test exercises them. The lithus monorepo is different: `mise nix-deploy` and `mise nix-install` run `nix flake check` as an eval gate before every NixOS host deploy, so `validate-cluster-stage1` and `stage2` do run there, on the host-deploy path (not on `kix deploy`, and not in CI).
- 2026-04-02: the scorecard framework arrived (b5f5735). New validation work moved there for good. `checks.nix` was never touched again on main.
- 2026-08-31: the ServiceMonitor selector bugs (#48) were caught live on stage1, not by any check. The rule written afterwards (#50) is a scorecard rule and caught a shipped bug on day one.
- 2026-09-07: #69 grew the allowlist for the first time in five months, because the monorepo's eval gate ran `validate-cluster-stage2` and kixpkgs has no equivalent gate.

The file's own header promises "clear, documented allowlists, not naming-convention heuristics". The operator exemption is a heuristic: kind on a list, plus "the Service name starts with the CR name", namespace ignored.

## 3. State at HEAD

- `validate-cluster-ludo-kind` is red. Six standing failures: three duplicate-resource reports that are false positives (the same resource appears twice in `rawManifests`; the output tree has one file each), and three real ones (derived CiliumNetworkPolicies carry no `managed-by` label). The red state is known (an agent flagged it to the team; the fix is pending). It does not stop `nix build`, which never evaluates the `checks` output.
- `validate-cluster-victoria-metrics` is red for the two Services #69 fixes.
- `kix check` does not run the 13 checks. Its source comment says cross-resource validation happens during eval; it does not. The monorepo's `flake.nix` says `kix check` runs the same checks as `validate-cluster-<n>`; it does not.
- The scorecard is off by default. In this repo only `ludo/base.nix` enables it, with the architecture rules only. stage1 and stage2 enable nothing, so on the live lithus clusters a `kix deploy` is refused only by a constructor throw; the 13 checks run for them only on the host-deploy path above.
- Cost is not the reason for any of this: the 13 checks add about 20 ms to a 291-resource eval. Forcing the manifests is 0.7 s and `nix build` pays that anyway.

## 4. What the break-it session showed

| Break | Constructor | Scorecard | 13 checks | `nix build` |
|---|---|---|---|---|
| Service selector typed by hand, labels correct | orphan warnings only | `selectorCoherence` warning | pass | green |
| Same, one label misspelled | same warnings | same warning, byte for byte | caught | green |
| Service for operator pods, kind not allowlisted | none | `selectorCoherence` warning | fails a correct build | green |
| Same, kind allowlisted, selector set to garbage | none | same warning | passes | green |
| ServiceAccount name as bare string | build fails | | | red |
| ServiceAccount via `kix.untrackedRef`, name wrong | none | nothing (no rule exists, `architecture.md` says one does) | caught | green |
| `self.sa.out.name + "-typo"` | none (provenance intact) | nothing | caught | green |
| Two Services with the same name | none | `distinctSameKindLabels` error, wrong diagnosis | never reached | red |

Reading the table:

- The provenance layer cannot tell a correct hand-typed selector from a broken one. Rows one and two are identical to it.
- The resolution layer is the only one that catches a misspelled selector or a dangling reference behind an escape hatch, and it is the layer nothing runs.
- "Correct by construction" holds for the literal shapes (`fromWorkload`, `serviceAccount = self.sa`) and stops there. Anything that keeps provenance while changing the value passes every guard except the 13 checks.
- On ludo-kind, 18 of 29 scorecard findings are `selectorCoherence` warnings, most on Services that have no workload to source from (control-plane scrape targets, operator operands). The advice they print cannot be followed. A warning that is usually wrong trains people to ignore it.

## 5. The operator case, seen from the packages

Two facts change the framing of #69:

1. Kix already has a primitive for a Service the operator creates: `scope.mkServiceRef`. `stackgres-cluster` uses it for exactly this (`default.nix:301`): the ref carries the operand selector and ports, renders as a PackageInstance marker, gates consumers until the Service exists, and feeds netpol. Neither the scorecard nor check 4 complains about it, because no `Service` manifest is emitted.
2. The VictoriaMetrics cluster package instead emits its own `-select` and `-insert` Services with hand-typed operand labels, for stable names and `out.serviceUrl`. That is what trips both layers. The operator already creates `vmselect-<name>` and `vminsert-<name>` Services; a `mkServiceRef` to those gives the same `out.fqdn` and removes the need for any allowlist entry. The prometheus package has the same shape and would get the same treatment.

So the allowlist was never the only way out for the VM stack. The question "where should the operator allowlist live" has a third answer: nowhere, if packages describe operator-created Services as refs rather than re-rendering them. A remaining case exists (a package that must own a Service selecting operand pods, for example for a different port set), and that case wants an explicit per-Service declaration, not a global kind list.

## 6. Verdicts per check

From the static read, with the session's evidence folded in.

| # | Check | Overlap today | Verdict |
|---|---|---|---|
| 1 | ServiceAccount exists | constructor checks provenance, not existence | keep, as a rule |
| 2 | roleRef exists | rbac DSL builds `roleRef.name` from the Role | keep, as a rule; provenance replaces the four-name allowlist |
| 3 | ConfigMap volume exists | constructor checks provenance | keep, as a rule; must honour `kix.untrackedRef` |
| 4 | Service selector matches a pod template | `fromWorkload`, `selectorCoherence` | keep the resolution check; delete the kind allowlist (section 5) |
| 5 | HPA target exists | none | keep, as a rule |
| 6 | StatefulSet serviceName is a headless Service | constructor checks kind, not `clusterIP: None` | keep, as a rule |
| 7 | No duplicate kind/namespace/name | `distinctSameKindLabels` catches same-instance cases with the wrong message | keep; only layer with full visibility; fix the input double-listing |
| 8 | `managed-by` label present | stamped by every constructor except `eval/namespace.nix` quota and netpol | redundant; fix the constructor gap and drop |
| 9 | Workload selector within template labels | `mkWorkload` copies or throws | keep only for Helm and raw workloads |
| 10 | Ingress backend Service exists | `ingress.fromService` | keep, as a rule; must accept imports |
| 11 | Namespace exists | `forNamespace` throws, Namespace always emitted | redundant; the sentinel `_cluster` shape is a separate design question |
| 12 | NetworkPolicy podSelector matches | none (plugin emits CNPs, a kind this check ignores) | keep as a warning |
| 13 | Named targetPort exists on a selected container | `fromWorkload` port check | keep, as a rule |

Bugs found along the way, independent of any decision: `rawManifests` lists three resources twice; derived CNPs and `eval/namespace.nix` quota/netpol lack the `managed-by` label; checks 4, 12 and 13 never see CronJob pods; `hasResource` falls back to the cluster-scoped bucket so a same-named cluster resource satisfies a namespaced lookup; the operator exemption ignores namespace; `hasOperatorResource` is dead code; `helm-dag.findOrphans` computes the intra-chart versions of checks 4 and 5 and nothing reads it; `mkHelmWorkload` runs no validators; no rule polices `kix.untrackedRef` despite `architecture.md:95`; `check.rs:170` and the monorepo `flake.nix:1086` describe checks that do not run.

## 7. What happened next (2026-09-08)

Adam agreed that `kix check` not running the checks was an oversight and asked for the fix, then for the operator-list removal. Two stacked PRs:

- **kixpkgs#72**: the 13 checks run inside every cluster eval (`kix/lib/eval/validate.nix`, fed into the cluster diagnostics), `rawManifests` is one entry per store path, derived policies and namespace resources carry the managed-by label, names wrapped in `kix.untrackedRef` and import markers resolve, CronJob pods are visible, the kix/lib test matrix is a flake check, HANDBOOK §17.4 documents the checks. Along the way: the test matrix had 13 of 54 cases failing on main (a fixture's `root` aliased no named part), and the ludo env-stamped variants had a real cluster-scoped name collision that the duplicate check now refuses.
- **Follow-up PR**: the prometheus, alertmanager and victoria-metrics-cluster packages use `scope.mkServiceRef` for the operator's own Services; a Service kix must render over operand pods declares `kix.dev/operand-of = "<group>/<Kind>/<name>"`; the operator-kind allowlist and the name-prefix guess are deleted. ServiceRefs carry the external Service's labels so self-monitors can select them.

Option 2 (move the checks into `kix/lib/rules/` with severities) and the `selectorCoherence` noise remain open. Section 8 keeps the original options for the record.

## 8. The options as first written (2026-09-07)

The earlier instinct, "retire the 13 checks in favour of the rules", was wrong. Provenance and resolution are both needed. What is wrong is that the resolution layer is dark, untested, fed a stripped and double-listed input, and gated behind an attribute nothing evaluates. Options, cheapest first:

1. **Turn the lights on.** Fix the two input bugs, make `validate-cluster-ludo-kind` green, run `validateManifestSet` inside the cluster build or at least inside `kix check`, and restore a CI job. Cost is 20 ms per eval and a few hours. Also enable the scorecard on stage1 and stage2 with the architecture rules, since today they run nothing.
2. **Unify the layers.** Move the resolution checks into `kix/lib/rules/` as cluster-level rules so they get severities, fixtures, SARIF, and one report. Needs a rule level that sees the full resource set (today cluster rules miss Namespace, kix CRDs and the Activation). Fix the CronJob, namespace and fallback bugs on the way. Days, not hours.
3. **Remove the allowlist.** Move VictoriaMetrics (and prometheus) operand Services to `mkServiceRef`; add a per-Service declaration for the residual case; delete `operatorManagedKinds`. Make `selectorCoherence` aware of refs and of Services that have no workload, so its 62 percent share of findings drops to the cases someone can act on.
4. **Doc 131 already carries the operand-attribution thread** (static `podSelector` on CRDs). Section 5 here is its Service-shaped corner; the two should be reconciled before either is built.

Open questions for Adam: should resolution checks gate `nix build` (an error stops the build) or report through the scorecard with severities? Should `selectorCoherence` become always-on as doc 126 proposes, given its current signal-to-noise? Is `mkServiceRef` the sanctioned way to consume operator-created Services in every operator package, so the allowlist can go?
