# 116: Migration playbook

**Status:** Draft (interactive build)
**Relevance:** Reference
**Related:** `68_migrate_non_kix_live_cluster.md`, `114_nw1_migration_plan.md`, `104_adam_customer_migration_readiness.md`, `113_lithus_kix_adoption_session.md`, `88b_flux_comparison_and_migration.md`, `67_stateful_migration_orchestration.md`, `58_satchel_mvp_technical_requirements.md`

## Why this doc exists

The nw1 migration (issue 114) was driven by a brute-force `kix-diff` convergence loop. It worked, but the AI-generated kix code was overfitted to the dump — reflecting *what was running* rather than *what should be true*. Future migrations need a playbook that goes **big idea → detail**, not **diff entry → patched package**.

This doc is the procedural counterpart to `68_migrate_non_kix_live_cluster.md` (the design) and the generalization of `114_nw1_migration_plan.md` (the case study).

## Scope

This playbook covers **migration from a live K8s cluster** (Helm releases, Ansible-applied YAML, hand-kubectl'd manifests). Example: `nw1/migration/` (k8s/ + helm/).

Terraform/IaC origins (e.g. `satchel_iac/Infrastructure/`) get a short appendix at the end describing what carries over and what doesn't.

## Source-vs-kix relationship — the staged stance

The nw1 mistake was treating the dump as a *spec* and overfitting kix to match it byte-for-byte. The right stance is staged:

1. **Start as option 1 — source as inventory.** Use the dump to enumerate services and their intent (versions, exposure, persistence, identity). Write idiomatic kix from scratch. Diff is allowed, freely.
2. **Move through option 2 — match runtime behavior.** Once the shape is right, tighten image tags, env, replicas, mounts to match what's running. Package layout stays independent of the dump's helm/ansible split.
3. **End at option 3 — diff-clean as a property, not a driver.** When the kix design is correct, evaluation should produce effectively the same resources as the dump. Remaining diff is *acceptable residue* (kix-internal markers, derived netpols, intentionally-disabled chart hooks) — not a backlog.

The diff loop is allowed throughout, but its role changes: in stage 1 it's a sanity check; in stage 2 it drives detail-tightening; in stage 3 it's a lint.

**Anti-pattern (nw1):** start in stage 3. Converging diff entry-by-entry produces packages that encode historical accident instead of intent.

---

<!-- Phases get filled in interactively. Outline below is the agreed shape;
each section is expanded section-by-section with the user. -->

## Phase 0 — SBOM-style scaffold, kix-first

**Posture:** work from the kix side, not the dump side. AI is in the loop — every step that's pattern-matching ("does this look like cert-manager?") is an AI step, not a human step.

The first iteration of kix code is intentionally **trivial**: a flat list of `PackageInstance` declarations with namespaces, no wiring, no values, no overrides. Treat it like an SBOM.

### Step 0.1 — Namespace map (orientation)

Read the live cluster's namespaces. For each, one line: *what concern lives here* (platform / operator / tenant / system / test). This is the only artifact that comes from the dump in Phase 0; it stops you from missing whole subsystems.

**Scope rule:** a namespace is in scope iff it has a Namespace declaration AND ≥1 non-policy resource. Namespaces that appear only as CNP/CCNP traces (no workload manifests) are *not* in scope — their CNPs are kix-derived netpol residue from upstream packages, not migration targets.

### Step 0.1.5 — Cluster identity extraction

Before SBOM mapping, extract one-liners (needed by Phase 1):

- Cluster name + environment (from labels, Connector names, helm release prefixes).
- Domain (from Ingress hosts).
- Service / pod CIDRs (from Tailscale Connector advertiseRoutes, kube-proxy config, or a representative ClusterIP).
- Worker node names (from DiskPools, nodeAffinity, nodeSelector).

### Step 0.2 — Match dump artifacts to existing kixpkgs

For each helm release and each Ansible bundle in the dump, the AI step is: **does kixpkgs already have a package for this?** Sort each artifact into one of four buckets:

1. **kix-native package exists** → include as an instance. Decide: Tier-2 importChart now (diff-cleanliness, fast adoption) → native switchover later, OR native immediately (intentional divergence). **Default: importChart-first, switch later** — this separates adoption risk from package-design risk.
2. **No kix package — write or import** → leave a `# TODO(116): no kix package — write or import` marker.
3. **Belongs as config / extra-resource on an existing package** → stray CRs that aren't components in their own right. Examples: SGObjectStorage on `stackgres-database`, Schedule on `velero`, PriorityClass on `reloader`, VirtualMachine on `kubevirt`, Connector/ProxyClass on `tailscale`. Canonical pattern: `CRDRef.mkCR` (see `kix/packages/stackgres-database/`). Without this bucket, AI defaults to inline-authoring or pretending it's a missing package — both wrong.
4. **Out of scope** → consciously dropped. Record in `OUT_OF_SCOPE.md` (see Step 0.3).

Match heuristics:

- Helm release name + chart name → grep `kix/packages/` for matching chart imports.
- Operator CRs (SGCluster, Cilium*, ServiceMonitor, …) → match to the package that owns that CRD.
- Native bundles (RBAC + Deployment + Service for X) → match by image, by name, by purpose.

### Step 0.3 — Write the SBOM cluster file

Produce a `cluster.nix` (or equivalent) that is *only*:

```nix
{
  instances = [
    { package = "cert-manager"; namespace = "cert-manager"; }
    { package = "ingress-nginx"; namespace = "ingress-nginx"; }
    { package = "stackgres-operator"; namespace = "stackgres-system"; }
    # ...
    # TODO(116): no kix package for `harbor` — defer
  ];
  # No values, no overrides, no flavor decisions yet.
}
```

The cluster *will not* build cleanly. That's fine. The point is to have a declarative inventory of what we *think* the cluster is, expressed in kix terms.

Also produce `OUT_OF_SCOPE.md`: namespaces/components consciously dropped (bucket 4 above), with re-add criteria. Bridges to Phase 5's `MIGRATION_RESIDUE.md`. Without this artifact, dropped scope vanishes silently and re-add hooks are lost.

Phase 0 exits when the SBOM is written and the gap list is enumerated. No package values have been touched yet. **The first diff is deferred to end of Phase 1** — diff is impossible until `nix build` evaluates; trying earlier conflates eval errors with real diff (see Step 1.4).

### Why this beats the nw1 approach

nw1 walked the dump and asked "how do I make kix produce this?". The result was packages that encoded the dump's accidents (chart-version drift, ansible-isms, helm hook artifacts) as kix code.

Working from kix side asks "which kix packages does the evidence support?". The leftovers are the real migration work, not the whole cluster.

## Phase 1 — Minimal viable cluster file (flavor + globals)

Goal: kix `nix build` evaluates. Not diff-clean, not feature-complete — just *evaluates*.

Only two decisions are forced in Phase 1; everything else is deferred.

### Step 1.1 — Pick a flavor

Three paths, in preference order:

1. **Default flavor (k3s, rke, eks, gke).** If the live cluster runs on a stock distribution and uses its default CNI/storage/ingress, pick the matching kix flavor. No flavor work needed in Phase 2.
2. **Fork an existing flavor.** If close-but-not-identical (e.g. lithus is "k3s + cilium + openebs + custom storage"), fork the nearest match and rename. Phase 2 then *extends* it.
3. **Write a new flavor.** Only when no existing flavor's capability set overlaps materially. Rare. The nw1 case justified this because of mayastor + ZFS + custom DiskPools per worker.

The flavor decision can be made together with the user / end use. The AI step here is: *given the dump, which kix flavor's capability fingerprint is closest?* (CNI in use, storage classes present, ingress controller, identity provider). Output: a one-paragraph justification for the pick.

### Step 1.2 — Set globals if known

Set globals you can read off the dump cheaply:

- Cluster name, environment.
- Domain (from Ingress hosts).
- Worker node names if any package needs them (e.g. per-node DiskPools).
- Service CIDR (visible from any ClusterIP Service range).

Do **not** set yet:

- `cluster.podHardening.profile` (Phase later — hardening is a deliberate pass).
- `cluster.backup` (Phase 5 — stateful work).
- Identity / SOPS (only when a package actually needs it).
- Per-package values, replicas, image tags.

### Step 1.3 — Wire instances to namespaces, fix eval errors only

Take the SBOM from Phase 0, plug it into the cluster file with the chosen flavor, and `nix build`. When it fails:

- Missing required option on a package → set to the dump's value if obvious, otherwise stub with the package default and leave a `TODO(116)`.
- Missing capability the flavor doesn't provide → either pick a different flavor, or note it as flavor work for Phase 2.
- Conflicting instances → drop one and `TODO(116)` the conflict.

The bar is **"evaluates"**, not "correct". Every value-fix is a candidate for revisiting in Phase 3.

### What the AI is doing in Phase 1

Pattern matching, three ways:

1. *Dump → flavor fingerprint.* "I see Cilium CRs and OpenEBS — closest flavor is `lithus`."
2. *Eval error → minimal stub.* "Package X requires `domain`; the dump's Ingress hosts are all under `*.nw1.example.com`; set `globals.domain = "nw1.example.com"`."
3. *Resource cluster → instance candidate.* "These 6 resources in `arc-runners` look like a `actions-runner-controller` chart import; add an `importChart` instance, defer values."

### Step 1.4 — First diff (deferred from Phase 0.4)

With `nix build` green, run the diff for the first time. The interesting numbers aren't only-in-right (expected) — they're:

- **What does kix emit that the dump doesn't have?** → packages picked wrongly, or packages that bring along scaffolding the dump doesn't.
- **Which dump namespaces have zero kix coverage?** → known gap list.
- **Which dump resources look like operator-managed children?** → should disappear once the operator package is wired (don't migrate them as native YAML).

Phase 1 exits when `nix build` is green, the first diff has been read, and a written list of deferred decisions exists.

## Phase 2 — Flavor (hardware reality)

A flavor encodes the **"hardware" reality** of where the cluster runs: distribution (k3s/rke/eks/gke/…), CNI, storage backend, node topology, identity provider, default ingress. It is **operator-chosen**, not diff-derived. The user knows what they're running on; ask them.

**Phase 2 ignores the diff entirely.** Flavor correctness is judged against the real cluster's hardware/platform truth, not against rendered manifests.

### Step 2.1 — Confirm the flavor with the user

Even when Phase 1 picked a default flavor automatically, confirm:

- Distribution + version (k3s 1.30, RKE2, EKS 1.29, …).
- CNI (cilium / calico / flannel / vendor default).
- Storage (cloud CSI / openebs flavor / longhorn / local-path).
- Ingress class (nginx / traefik / gateway).
- Identity (cloud IAM / OIDC / SOPS-only).
- Node topology if it matters (single-node / HA / per-node specialization).

Output: a short flavor profile written into the cluster file or a flavor module. Verbatim from the user where possible.

### Step 2.2 — Implement only what the flavor *claims*

The flavor advertises capabilities (storage, ingress, identity, CNI policy enforcement). Phase 2 fills those slots with working implementations and **stops**:

- StorageClass + CSIDriver wired and reachable from a test PVC.
- Ingress class actually serves a test ingress.
- CNI policy enforcer reachable for netpol DI to use.
- Identity capability wired enough that packages can request a SA / token.

Whether the rest of the cluster diffs cleanly is **not** Phase 2's concern. Per-package overrides, image tags, replicas, env values all stay deferred.

### Step 2.3 — Defaults > customization

Take flavor defaults wherever they exist. Customization (storage tuning, custom snapshot classes, per-node pools, alternative ingress configs) is a **finetuning pass after Phase 3** — when the cluster is otherwise diff-close, it's much clearer which customizations are real intent vs accidents of the source.

### What the AI is doing in Phase 2

Translating a user-stated profile into a flavor module. *Not* inferring the flavor from the dump (Phase 1 did a sketch, the user confirmed the truth). *Not* converging on the diff.

Phase 2 exits when the flavor module evaluates and the capabilities it claims are observably wired (a test PVC binds, a test Ingress routes, etc.).

## Phase 3 — Diff resolution

This is where stage 1 → 2 → 3 happens. The AI is doing the heavy lifting; the playbook constrains *how* it works, not the order it tackles things.

### Two non-negotiable rules

1. **`nix build` green before any diff work.** kix has dependency injection — missing wiring shows up as eval errors, not as silent diff. Tactically fix eval first, every time. Never resolve a diff entry while the build is red.
2. **`docs/FEATURE-CATALOG.md` is required reading.** Before reaching for a raw override or extending a package, the AI confirms there isn't already a feature that solves it. Skipping this is the #1 cause of overfitted slop.

### Traversal order

Not prescribed. The AI picks. DI errors and the diff hierarchy below provide enough structure; topological ordering is mostly redundant with kix's own eval errors.

### Diff-resolution hierarchy

Resolve in this order — *never* skip a level for a lower one. A diff at level *n+1* should not be looked at while level *n* still has open items.

1. **Missing instances / packages.** Whole logical components present in the dump, absent in kix.
   - If a kix package exists but isn't instantiated → instantiate it.
   - If no kix package exists → break out of the playbook and hand off to the **package migration skill**, or wrap the live helm chart as an `importChart` instance. Don't try to inline it as raw resources in the cluster file.

2. **Missing resources within an existing instance.** Use `compare-cluster-dump.py --files-only` to drive this — file-level presence, body-blind. Strategy is per-cluster of resources: the missing file may be a flag on the package, an extra-resources hook, a sub-feature, or a configuration that produces it. Think before patching.

3. **Resource bodies (the meat).** Spec fields, env, mounts, replicas, image tags, command/args. The biggest bucket; the most package-option-mappable.

4. **Config files.** ConfigMap/Secret payloads — usually values that drive (3) but appear as their own diff entries.

5. **Labels and annotations.** Fine-tuning. Often cosmetic helm-isms (`meta.helm.sh/release-*`, `checksum/config`) that belong in *acceptable residue*, not in resolution.

### Per-step discipline

- **Most minimal change.** Always. If a one-line option fixes it, no helper module. If a value override fixes it, no package extension.
- **Strategy first, then change.** State the hypothesis ("this should be a `replicas` option on the package") before editing.
- **Failed strategy → drawing board, not escalation.** If the change didn't produce the expected diff delta, do *not* patch around it. The mental model was wrong; rebuild it. Head-through-wall approaches do not work and produce the worst overfit.
- **FEATURE-CATALOG.md before any new code.** "Is there already a feature for this?" is the first question every step.

### Resolution choice — extend / override / accept

When the dump's behavior doesn't fit cleanly, prefer in this order:

1. **Extend the package.** Right when the same option would matter to any other user of this package. The migration discovered a real gap.
2. **Override in the cluster file.** Right for environment-specific accidents that don't generalize.
3. **Accept the diff.** Right when the dump is *wrong* (helm-hook artifacts, ansible-isms, chart-version drift you don't want to preserve). Move it to acceptable residue.

### Package-authoring handoff (sub-procedure of level 1)

When level 1 says "no kix package exists", the migration owner stops and hands off. Two paths:

- **Wrap as helm chart.** If the source is a helm chart and customization is shallow, use `importChart`. The handoff package is small: chart name, version, values from the dump, namespace, any DI capabilities the chart needs (storage, ingress).
- **Write a kix package.** If the source is native YAML, an operator+CRs combo, or a chart with deep customization, hand off to the **package migration skill** with: chart or YAML source, dump excerpts of all rendered resources, the intent (one paragraph from Phase 0).

The migration owner does not author packages inline as part of Phase 3. That's the boundary that prevents overfit.

### What "done" looks like for Phase 3

The diff is residue-only — the categories enumerated in *Acceptable residue* below — and every non-residue diff entry has been intentionally chosen (extended / overridden / accepted), not patched-around.

## Phase 4 — Adoption-readiness diff

Up to here, nothing has been deployed. The kix tree produces a closure equal-by-intent to the live cluster, with diff residue-only.

Phase 4 is **not** a data migration phase — that's owned by `67_stateful_migration_orchestration.md` (orchestrating stateful changes) and `108_backup_capability_contract.md` (restore as the gate). Read those before any first-apply.

What this phase *does* own: producing the **adoption diff** — the explicit list of differences between what kix will apply and what's live, classified by what the operator must do before kix can take over reconciliation safely.

### Step 4.1 — Generate the adoption diff

Run the diff one more time, but with a different lens than Phase 3. Phase 3 asked "is the kix output correct?". Phase 4 asks "what will change on the live cluster the moment kix takes over?".

Three buckets:

1. **Ownership transfers.** Resources currently labeled by Helm (`app.kubernetes.io/managed-by: Helm`, `meta.helm.sh/release-name`) or Ansible. kix doesn't replace these magically — `helm uninstall --keep-history=false` first, or relabel/annotate to drop helm ownership before `kix apply`. List every helm release in scope.
2. **Field-level drift kix will overwrite.** Cluster-side mutations not expressed in the dump (manual `kubectl edit`, controller-added fields, hand-tuned replicas). Each one is a decision: encode it in kix, accept it being overwritten, or leave the resource out of scope on first apply.
3. **Resources kix will delete.** Anything live but absent from kix output. This is the highest-risk bucket — never leave it implicit. Either add it to kix, mark it pre-deleted out-of-band, or scope-exclude.

The output is a written, reviewed checklist. Not a tool report — a document the operator signs off on.

### Step 4.2 — Manual adaptation pass

Some entries in the adoption diff are unavoidably manual:

- Strip helm ownership labels/annotations on resources kix will adopt.
- Pause the existing Ansible/Argo/Flux reconciler so it doesn't fight kix.
- Pre-create namespaces or CRDs that have ordering dependencies kix's first apply can't satisfy in one pass.
- Migrate Secrets that the dump has but kix expects to come from SOPS — without exposing them in the dump.

The playbook lists the categories; the operator works through them with the adoption diff in front of them.

### Step 4.3 — First apply (scoped)

First apply is **not** cluster-wide. Pick a low-risk namespace from the adoption diff (a stateless platform component, not a tenant DB), apply, observe, roll back if needed. Expand scope namespace by namespace.

Stateful cutover (PVCs, databases, restore-rehearsals) hands off to doc 67 + 108 at this step. The playbook does not redocument data migration.

### What "done" looks like

The cluster is reconciled by kix; the previous reconciler (Ansible, Helm, Flux) is decommissioned for the in-scope namespaces; the adoption diff is empty or every remaining entry is consciously out-of-scope.

## Phase 5 — Switch the source of truth

A short, mostly-organizational phase.

- **Decommission the old source.** Archive Ansible playbooks, drop helm releases from CI, remove TF modules that managed K8s resources. Keep them readable for one release cycle as escape hatches.
- **Make kix the only writer.** Any remaining manual `kubectl apply` paths get converted to kix instances or removed. Drift from now on is a kix bug.
- **Document the residue.** The "acceptable residue" list from Phase 3 + the "consciously out-of-scope" list from Phase 4 become a `MIGRATION_RESIDUE.md` in the cluster repo, so future readers don't mistake known-acceptable drift for real drift.
- **Wire the loop.** kix in CI, scorecard rules enforced, deploy verbs (`kix deploy`, `kix history`, `kix drift`) replacing whatever existed before.

## Acceptable residue

Diff entries that are *expected* and not migration work. The migration is done when remaining diff is in these categories.

- **kix-internal DAG markers.** `PackageInstance` records, kix CRD-ref placeholders for chart CRDs, derived resources kix emits to wire its own dependency graph. No live analog.
- **Derived NetworkPolicies / CCNPs.** kix derives per-workload netpols from DI; the dump usually has hand-rolled CCNPs at namespace granularity. Both correct, structurally different.
- **Intentionally-disabled chart hooks.** cert-manager `startupapicheck`, openebs upgrade hooks, stackgres `sgconfig` install/remove Jobs. kix packages disable these on purpose; do not re-enable to chase diff.
- **Operator-managed children.** Pods, Endpoints, EndpointSlices, ReplicaSets — never authored, always derived. Filter from diff input.

**Not residue (common mistakes):**

- **Helm-conventional labels/annotations** (`meta.helm.sh/release-*`, `app.kubernetes.io/managed-by: Helm`, `checksum/config`) are *not* cosmetic. Without them, pod-template hashes change at cutover and workloads restart — that's an outage, not a cosmetic detail. Tracked as an open question (helm-compatible mode flag).
- **Chart-version drift.** Two cases:
  - *Live cluster uses a helm chart, kix uses its own native package.* Diff is real and intentional — the kix package's wiring deliberately differs. Treat as a migration-result flag, not residue. The operator decides whether to converge on the kix-native shape or stay closer to the chart.
  - *Live cluster and kix both use the chart.* Pin the exact live version via `fetchHelmChart` (or inline `kix.helmChart { version = "..."; hash = "..."; }`). No reason for version drift. Diff should be empty modulo deterministic strip/normalization.

## Tooling

- **`scripts/compare-cluster-dump.py`** — diff between `nix build` output and a dump.
  - Default: full diff.
  - `--files-only` — file-presence-only; drives Phase 3 level 2 (missing resources).
  - `--broken-only` — surfaces structural breakage; useful while `nix build` is green but resources are obviously malformed.
  - `--ns <ns>` — scope to one namespace.
  - `--summary` — convergence numbers (only-L / only-R / equal / diff).
- **`docs/FEATURE-CATALOG.md`** — required reading before extending packages or adding overrides. The single biggest lever against overfit.
- **`kix.helmChart` (Tier 1)** and **`scope.helm.importChart` (Tier 2)** — see Helm imports below. The default path for any helm-sourced component.
- **Package migration skill** — handoff target when a native (non-helm) package needs to be authored.
- **Per-cluster wrapper script** (optional) — pins dump location, render-helm step, default flags. Worth writing once per migration; not part of the playbook itself.

### Helm imports — not a shallow wrapper

`kix/lib/helm.nix` is a fully-integrated bridge that produces resources behaving like native kix resources. Knowing what it actually does is what keeps Phase 3 level-1 handoffs from defaulting to "rewrite native":

- **IFD-driven `helm template` with version+hash pinning.** `fetchHelmChart` is a fixed-output derivation; `helmTemplateDerivation` runs `helm template` against a JSON values file. Reproducible, exact-version pinnable.
- **DAG reconstruction across the chart.** `helm-dag.nix` infers intra-chart edges (selector matches, owner refs, ConfigMap/Secret references, RBAC bindings). Each wrapped resource carries its inferred `requires` list, so chart resources order themselves through the kix DAG via `kix.dev/depends-on` exactly like native ones. `mkParts` exploits this: root only directly requires DAG entry points; everything else is reached transitively. Forward-closure behavior is identical to native packages.
- **Per-workload CNP generation.** Workloads (Deployment/StatefulSet/DaemonSet/Job) route through `scope.mkHelmWorkload`, not raw `mkResource` — same per-workload netpol derivation native packages get (DNS egress, cross-package service egress, self-ingress for StatefulSets).
- **Cross-package wiring.** `networkDeps` injects store-path context from other packages' DI outputs (e.g. `loki.out.fqdn`) into helm workloads as `_helmNetworkDeps`, so `extractServiceEdgesFromJson` discovers cross-package egress edges. `extraEdges` adds intra-chart deps the inference missed.
- **Strip control with per-prefix opt-out.** `strip = { helmAnnotations, helmLabels, defaultStrategy }` plus `preserveAnnotationPrefixes` — the partial primitive for the helm-compat-mode open question below.
- **Pre-wrap patching.** `patchResources` runs before wrapping: fix chart bugs, drop unwanted resources, mutate metadata.
- **Capability publishing.** `mkParts { ..., out = { ... }; }` lets imported charts expose DI capabilities (Service refs, FQDNs, CRD refs) so downstream packages depend on `chart.out.x` exactly like `native.out.x`.
- **Two tiers, deliberately:**
  - **Tier 1 — `kix.helmChart { repo; name; version; hash; }`** inline in the cluster definition. Zero-friction; uses `autoRoot`. Right when you have nothing to add to the chart.
  - **Tier 2 — a real package whose `build` calls `scope.helm.importChart { ... }`.** Full control: explicit root, custom `out`, `extraParts` for CRD refs, `extraEdges` for missed deps, `networkDeps` for cross-package wiring, `patchResources` for mutations. Right whenever you'd otherwise reach for a kix-native rewrite for non-customization reasons.

**Implication for Phase 3 level-1 handoffs.** The default for a helm-sourced component is **Tier 2 importChart**. Native-package authoring is reserved for:

- Sources that aren't helm (operator+CRs hand-written, ansible bundles).
- Charts with so much customization that the override surface is bigger than the chart itself.
- Charts where upstream is dead and we want full ownership.

Exact-version-pinned Tier 2 importChart is diff-clean modulo deterministic strip/normalization (also opt-outable per-prefix).

## Anti-patterns from nw1

The nw1 migration is the cautionary tale this playbook is shaped against. Re-listed so future readers recognize the failure mode:

- **Diff-entry-driven coding.** Treating each diff line as a ticket and patching kix until it disappears. Produces packages that encode the dump's accidents (helm hook artifacts, ansible-isms) as kix code.
- **Working from the dump side, not the kix side.** Walking 955 dump resources before knowing which kix packages cover them. Phase 0 (kix-side SBOM) is the corrective.
- **Skipping `nix build` green.** Trying to reduce diff while eval is red. DI errors get masked by raw overrides; ownership becomes incoherent.
- **Skipping FEATURE-CATALOG.md.** Inventing a custom mechanism for something a kix feature already solves.
- **Defaulting to native-rewrite when a chart exists.** Tier 2 importChart is the default; only escalate to native authoring when the criteria above are met.
- **Head-through-wall iteration.** When a strategy doesn't produce the expected diff delta, escalating (more overrides, deeper patches) instead of going back to the drawing board. The mental model was wrong; layering on top of a wrong model produces the worst overfit.
- **Inline package authoring.** Writing package-shaped logic in the cluster file because handing off felt like a delay. Ends up half-package, half-cluster, fully unreusable.
- **Phase confusion.** Doing Phase 3 detail work while Phase 2 capabilities aren't real, or chasing label/annotation diff (level 5) while resources are still missing (level 2).
- **Treating CNP-only namespace traces as scope.** A dump can carry 50+ CNPs referencing tenant/operator namespaces with no workload manifests. Misreading these as missing packages explodes scope. Rule: in scope iff Namespace declaration AND ≥1 non-policy resource (see Step 0.1).

## Open questions

- **Helm-compatible mode flag.** kix needs an opt-in mode that emits helm-conventional labels and annotations (`app.kubernetes.io/managed-by`, `meta.helm.sh/release-name`, `meta.helm.sh/release-namespace`, `checksum/config` on pod templates) so that an adoption cutover doesn't change pod-template hashes and force workload restarts. `preserveAnnotationPrefixes` is a partial primitive; the full semantics — deterministically synthesizing `release-name`/`release-namespace`/`checksum` — needs design. Scoped per-instance, ideally removable after a stabilization window.
- **Migration-result flag for kix-native-vs-chart wiring divergence.** When the cluster uses a chart and kix has a native package with deliberately different wiring, the operator needs an explicit per-instance flag marking "diff here is intentional".
- **Operator self-host during cutover.** When kix itself runs as the in-cluster operator, who applies the operator manifest on first cutover? Hand-applied? Bootstrap from CI? Cross-references doc 62.
- **Multi-team adoption diff.** When several teams own different namespaces on the same cluster, the adoption diff (Phase 4.1) needs a per-team slice. Tooling doesn't support this yet.
- **Greenfield-from-TF (no live cluster).** The Terraform appendix below sketches the substitution but the diff loop is absent; what plays the role of "convergence metric" without a live target?
- **Stateful first-apply ordering.** When a stateful component (database, registry) lives in scope-1 of cutover, the playbook punts to docs 67 + 108. Whether the playbook should sequence them inline is an open question.
- **Adoption-diff tooling.** Currently produced by hand from `compare-cluster-dump.py` output + helm-release inspection. Worth a dedicated subcommand?

## Appendix — Terraform / IaC origins

When the source is Terraform Cloud (or similar IaC) rather than a live K8s cluster, most of the playbook still applies but two phases shift:

- **Phase 0 (SBOM) carries over.** Walk TF modules instead of helm releases / namespaces. Group modules by concern (network → CNI/cluster.network; database → stackgres / CNPG; secret_manager → SOPS + ESO; monitoring → flavor monitoring; api / frontend / scanner → workload packages; permissions → identity capability). Output is the same: an SBOM-style instance list, kix-side.
- **Phase 1 + 2 carry over unchanged.** Flavor pick, globals, capability fill — TF often has these decisions explicit (cloud distribution, CSI add-on choice, IngressClass). Cheaper than reading from a live cluster.
- **Phase 3 has no diff loop.** No live cluster → no dump → no diff. Substitute: build greenfield, validate against a staging cluster brought up via the new kix tree, treat *staging-vs-prod-TF* as the convergence metric for one cutover. Shape work (FEATURE-CATALOG, extend / override / accept, minimal-change discipline, Tier 2 importChart default) is unchanged.
- **Phase 4 changes shape.** No adoption — staging is greenfield. The "adoption diff" becomes a "cutover plan": destroy TF-managed K8s resources, apply kix, verify. TF stays in charge of non-K8s infra (VPC, IAM, DNS zones) unless those are also in scope.
- **Phase 5 unchanged.**

Open: greenfield-from-TF without a staging cluster (true cold start) has no convergence metric at all. The playbook does not currently cover that case.
