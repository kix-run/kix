# 84: M0/M1 Implementation Plan — Closing the Demo Gap

**Status:** Draft
**Related:** `66_milestone_roadmap.md`, `58_satchel_mvp_technical_requirements.md`, `51_demo_plan.md`, `52_demo_implementation_todo.md`

---

## Why this document

`66_milestone_roadmap.md` sets the strategic sequencing (M0 dogfood → M1 pilot-ready → M2 ops leverage → …) and the §"Developer Productivity as Table Stakes" section pulls a concrete set of rig-style features forward into M1. This document turns that into an **actionable engineering plan** grounded in the current `kix/lib/` and `cli/` code — file paths, which existing machinery to reuse, what's out of scope, and a week-one sequence.

It is deliberately narrow. Everything here is M0 or M1. M2+ work is explicitly excluded even where tempting.

---

## Framing: the demo is the artifact

Per roadmap §"The demo implication", the single highest-leverage output of the next push is a **15-minute demo** that runs:

```
kix deploy → kix status → kix logs → edit + kix diff → kix rollback → same on N clusters
```

Everything below is sequenced to close that demo gap. Capabilities already exist in the engine (see `kix/lib/architecture.md` non-obvious patterns: store-path DAG, Activation CR as deploy root, identity-hash change detection). Most remaining work is **CLI surface, output polish, and reference content** — not new engine code.

The rig founder feedback (docs 28, 29) is blunt: the VP Eng sale closes on surfaced commands, not on capabilities that exist in the engine but can't be demoed in 30 seconds.

---

## Tier 1 — M1 demo-critical (ship first)

Thin wrappers over existing machinery. One concrete PR per bullet.

### 1. `kix export` — exit-strategy command

- **Where:** new `cli/kix-cli/src/commands/export.rs`; register in `cli.rs`.
- **Mechanic:** walk the fresh `StoreGraph` (same path `commands/diff.rs` uses for build-to-build mode), write `namespace/Kind-name.yaml` via `manifest::serialize`. Strip `kix.dev/*` annotations on the way out — reuse `cluster/normalize.rs` helpers.
- **Modes:** `--for=exit` (strip kix annotations, fully neutral YAML) vs `--for=audit` (preserve provenance annotations). Default `exit`.
- **Why first:** trivial, unblocks the Sam "exit strategy" story, and the `audit` mode becomes M3 compliance-evidence packaging for free.

### 2. `kix rollback` UX surfacing

- **State today:** `commands/rollback.rs` works via `find_most_recent_superseded` from `cluster/activation.rs`. Missing: history listing and change summary.
- **Work:**
  - `kix rollback --list` prints `Records::rollback_targets()` with timestamp, source path, identity-hash, previous-activation link.
  - On confirmation, render package-grouped diff via `plan::print_package_plan` against the current Active CR so the operator sees exactly what flips before approving.
- **No engine work.** Pure CLI plumbing + output formatting.

### 3. `kix status` audit against the rig spec

- **State today:** `commands/status.rs` is ~656 lines — it exists but needs an audit against the rig checklist ("what is running, is it healthy, what changed, who changed it").
- **Work:**
  - Read `status.rs` end-to-end; list gaps against the checklist.
  - Required output: per-package rows with
    - health (`readiness::wait_for_ready` one-shot mode),
    - drift (`cluster/normalize.rs::detect_drift`),
    - last-changed-by (read from the Active Activation CR's stamped fields; walk `status.previousActivation` chain).
  - Stamp deploying user + git commit into the Activation CR at `begin_deploy()` time so last-changed-by has a source.
- **Sub-task:** extend `cluster/activation.rs::begin_deploy` (and its `ReconcileConfig` call path) to accept and persist `{ git_commit, user }` into status. Status subresource → no generation bump → operator reconcile-loop filter (see `cli/README.md` §"Operator reconcile loop prevention") already handles this.

### 4. `kix logs <package>` and `kix pf <package> <port>`

- **Where:** new `commands/logs.rs`, `commands/pf.rs`.
- **Mechanic:** resolve `<package>` to its workload resources via `StoreGraph::PackageNode.resource_paths`, find the `Deployment`/`StatefulSet`/`DaemonSet` and its pod selector (already in `out.selector` per `compose.nix`), shell out to `kubectl logs -l <selector>` / `kubectl port-forward`.
- **Deliberately shelling out.** The point is "one tool" in the demo, not re-implementing log streaming. Zero library changes.

### 5. Diff-before-deploy confirmation modal + structured output

- **State today:** `commands/deploy.rs` already shows the package-grouped plan via `plan::print_package_plan` and confirms before applying. `commands/diff.rs` has three modes (build-to-build, vs live, vs snapshot).
- **Gap:** structured output usable by both the CLI modal and a future PR-comment / web-dashboard consumer.
- **Work:**
  - Add `--output json|human|markdown` to `kix diff` (markdown = PR comment format).
  - Extract the diff rendering from `diff.rs` into a shared `plan::render_structured_diff(&PackageDiff, Format)` so the deploy modal, `kix diff`, and the PR-comment GitHub Action all consume the same producer.
- **Touches:** `kix-cli/src/plan.rs`, `kix-cli/src/commands/diff.rs`, `kix-cli/src/commands/deploy.rs`.
- **Unblocks:** #2 (rollback change summary), #3 (status formatting), #8 (CI action). **Do this first.**

---

## Tier 2 — onboarding friction

Demo is useless if a new user can't reach it.

### 6. `kix init --provider gke|eks|kubeadm`

- **Where:** new `commands/init.rs`.
- **Mechanic:** template `flake.nix` + `clusters/<name>.nix` with the flavor preset, starter instances (ingress-nginx + cert-manager + kube-prometheus-stack). Templates as embedded strings via `include_str!` under `cli/kix-cli/templates/`.
- **Hetzner:** no `hetzner.nix` flavor today. Ship as `--provider kubeadm` + docs; adding a dedicated flavor is M2 work, but M0 dogfood may force the decision earlier.

### 7. GKE flavor completeness + `clusters/example-gke.nix`

- **Work:** verify `kix/lib/flavors/gke.nix` sets all `cluster.capabilities.*` correctly (storage class, LB type, network policy API, DNS provider). Many M1 consumers read `config.cluster.capabilities.*` directly — gaps here cause silent wrong config.
- Per `architecture.md` non-obvious pattern "Platform imports are shadowable," flavors should also provide `mkImport` instances for platform-managed services. Roadmap schedules this for M2, but a clean GKE reference cluster needs at minimum `platform-dns` and `platform-storage` today.
- **Deliverable:** `clusters/example-gke.nix` that evaluates cleanly and runs the full demo set end to end.

### 8. CI integration — GitHub Action

- **Where:** new `.github/actions/kix-diff/`, `.github/actions/kix-deploy/`, and a reference `.github/workflows/kix.yml`.
- **Depends on:** #5 (markdown diff output).
- **Includes:** Nix binary cache setup guide (Cachix or attic) so CI isn't 20 minutes of rebuild per PR.

### 9. Multi-env pattern + Terraform → `mkImport` bridge docs

- **Where:** `docs/guides/multi-env.md`, `docs/guides/terraform-bridge.md`, plus a worked `clusters/example-multienv.nix`.
- **Mechanic for the bridge:** document `mkImport` consuming a JSON file produced by `terraform output -json > .tfout.json` and read at eval time via `builtins.fromJSON (builtins.readFile ./.tfout.json)`. No new library code — already supported by `kix.mkImport` (see `eval/import.nix`).
- **Reference** the two existing mechanisms: `eval/import.nix` and `modules.nix` flavor capabilities.

---

## Tier 3 — service catalog gaps

Packages missing for the "table stakes" cluster. One `kix/packages/<name>/default.nix` each.

### 10. `external-secrets-operator`

- Helm-wrap via `kix.fromHelmChart` — see `kix/lib/helm.nix` and an existing helm-wrapped package (`cert-manager`) for the template.
- Declare `meta.provides = [ "external-secrets" ]` and define `rootOut` with a DI builder so consumers can request secrets by name. Same pattern as `reflector.out.reflectSecret` called out in `architecture.md` non-obvious patterns.

### 11. Loki + promtail verification

- Packages already exist (`kix/packages/loki`, `kix/packages/promtail`). Verify they wire correctly alongside `kube-prometheus-stack` on GKE. Validated via `clusters/example-gke.nix` end-to-end build.

### 12. `kube-prometheus-stack` GKE verification

- Verify auto-wiring (`kix/lib/modules/monitoring.nix`) matches GKE capabilities, ServiceMonitors discovered, storage class resolves via the flavor.

---

## M0 — the reference stack (parallel track)

Runs in parallel with Tier 1; uses only already-shipped capability. This is the asset everything else depends on for social proof and demo content.

- **Goal:** one production-ish cluster on Hetzner running 5–10 real services, operated daily.
- **Work:** `clusters/dogfood.nix` with ingress-nginx, cert-manager, kube-prometheus-stack, loki+promtail, external-secrets-operator (from #10), and 2–3 apps (`vaultwarden`, `immich` — both packages exist).
- **Operational loop:** use it from day one via `kix deploy --operator` so the operator path gets daily mileage and catches drift/reconcile bugs before customers do.
- **Output:** a doc "this is our cluster, built in a day, here's the graph" that becomes the M1 sales demo backdrop (see `51_demo_plan.md`).

---

## What is deliberately NOT in this plan

Explicitly out-of-scope for M0/M1 per the roadmap; pulling any of these forward dilutes focus.

- **Network policy API abstraction** (M2) — `netpol.nix` is Cilium-only by design today; document it as such, don't generalize yet.
- **`kix gc` without cluster eval** (M2).
- **Deploy target verification** (M2) beyond the git-commit/user stamping in #3.
- **Merkle-walk integrity check** (M2).
- **Partial deploy / break-glass escape hatches** (M2).
- **Canary rollouts, PR previews, web dashboard, service catalog UI** (M5) — except the diff structured-output extraction (#5), which we pull early because every earlier tier depends on it.
- **Compliance exports, SBOM, OSCAL, SLSA surfacing** (M3). Per roadmap §"Compliance as a layer," M3 is mostly *packaging* of M1/M2 outputs, so `kix export --for=audit` (#1) is the only compliance-adjacent work we do now.
- **Full operator git-watching** (M5).

---

## Suggested week-one sequence

1. **#5 diff output extraction.** Unblocks #2, #3, #8. Do this first.
2. **#1 `kix export`.** One afternoon. Ships exit-strategy story. Nothing depends on it.
3. **#2 rollback UX** + **#3 status audit** in parallel. Both CLI-layer work over existing engine.
4. **#4 logs + pf.** Trivial wrappers. Batch with #3.
5. **#7 GKE flavor + example cluster.** Becomes the harness for #11/#12 and M0.
6. **#6 `kix init`**, **#8 CI action**, **#10 external-secrets.** Parallelizable once the foundation is in.
7. **M0 dogfood cluster.** Start in parallel with #1; only needs what already ships.

---

## Open decisions

- **Hetzner as flavor or `kubeadm` + docs?** Deferring the flavor is cheaper, but M0 dogfood may force an explicit flavor earlier. Revisit when `clusters/dogfood.nix` hits its first capability gap.
- **`git_commit` / `user` stamping into Activation CR** (needed for #3 last-changed-by): part of `begin_deploy` signature, or a separate `ReconcileConfig` field? Affects the `kix` library API surface, not just the CLI. Preference: extend `ReconcileConfig` — keeps `begin_deploy` focused and lets the operator reuse the same plumbing.
- **`kix export` annotation-stripping default:** `--for=exit` (strip) matches Sam's lock-in concern; `--for=audit` (preserve) matches the compliance story. Default to `exit` because M1 is the pilot milestone, not the compliance milestone.
- **Does #3 (`kix status`) need a machine-readable mode now?** Probably yes — same argument as #5. A `--output json` at the start is cheaper than retrofitting it when the dashboard (M5) lands.

---

## Success criteria

M0/M1 is done when all six steps of the demo run end-to-end against a real cluster (the M0 dogfood stack), with no manual `kubectl` invocations inside the demo window, and a new user can reach the same demo from `kix init` in under an afternoon.

Tracking: mark each tier item `[x]` in `ROADMAP.md` as it lands, keep `cli/README.md` current per the CLAUDE.md rule, and update `kix/lib/architecture.md` only if any of the non-obvious patterns shift (none expected — this is surface work, not engine work).
