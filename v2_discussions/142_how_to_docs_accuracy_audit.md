# 142: How-to docs accuracy audit and the verification gap

**Status:** All five phases landed 2026-09-16 on
`docs/how-to-cluster-safety-fixes`, thirteen commits from `726afe2`.
kix-examples PR #1 is merged and the docs lock points at it. What remains is
follow-on pipeline work and two design questions, listed under "What remains"
below.

**Related:** `135_validation_layers_audit.md` (same question one layer down: what
validation actually runs), `docs/README.md` (snippet + capture pipeline)

## Context

Codex wrote the 87 guides under `docs/src/content/docs/how-to/**` between
2026-09-09 and 2026-09-14. They total about 6,500 lines across roughly 40
commits and had not received a complete human review. This document records
the review findings, corrections made during a second audit, and the resulting
changes to the documentation pipeline.

Five reviewers divided the corpus by category and checked every claim about an
API or behavior against `kix/lib/` or `cli/`. A separate adversarial review
then looked for false positives in their findings. Three questions about Nix
semantics were resolved by running `nix eval`. The fix commits contain detailed
citations; this document summarizes the results.

The guides generally follow Kix conventions. They do not invent spec keys or
copy Helm patterns mechanically. Package roots are handled consistently,
secrets use `mkSecret` or `mkSecretRef`, and monitor selectors come from the
Service. The main problem is factual accuracy, concentrated in areas that the
documentation pipeline does not verify.

## The verification gap

The docs pipeline is better than most. Snippets are region-extracted from real
`.nix` files (`docs/nix/snippets.nix`), command output is captured from real
runs (`docs/nix/captures.nix`), offline captures are drift-gated in CI, and
`check-how-to-coverage.mjs` keeps a ledger honest against the content tree.

The pipeline does not verify three important areas:

1. **Prose claims.** Most confirmed errors were statements about behavior, and
   the pipeline has no way to check them.
2. **Hand-written fenced blocks.** 19 of 87 pages carry raw ```nix or ```yaml
   blocks that no derivation evaluates. Nearly every example that failed during
   evaluation came from one of these blocks. Both hand-written blocks in
   `select-and-configure-a-cluster-flavor.mdx` were broken.
3. **Whether the examples would actually apply.** Every `check.json` in the
   corpus reads `kubeconform pass (skipped, not installed)` and `scorecard skip
   (not enabled in cluster definition)`. Of roughly 30 captures in the
   platform/package set, 3 are `generator: "live"`. The rest are eval-only.

The harness proves that extracted snippets match their sources and that
captured commands produced the displayed output. It does not prove that the
surrounding explanation is correct, that hand-written examples evaluate, or
that an API server would accept the resulting manifests.

The defects closely follow the boundary of the automated checks. Strengthening
those checks will prevent more errors than correcting individual sentences
after publication.

## Findings inventory

### Tier 1: would break or destroy something

| ID | Page | Defect |
|---|---|---|
| T1.1 | `deploy-with-dry-run-...` | The guide presented `--prune-mode eager` as an ordering option, but `deploy.rs:727-731` mapped it directly to deletion. No interleaving behavior existed. |
| T1.2 | `preserve-existing-selectors`, `preserve-helm-compatible-labels` | Both guides recommended `kix diff` to compare immutable selectors before takeover. The live-state query includes only resources labelled `app.kubernetes.io/managed-by=kix` (`fetch.rs:66,321`), so it cannot find the resource before Kix adopts it. The diff shows an addition and never compares the selector. |
| T1.3 | three takeover pages | The guides told readers to review conflicts before using `--force-conflicts`. Because `on_error` defaults to `stop` (`cli.rs:423`), the dry run checked only the first conflicting resource. The captures themselves ended with several resources cancelled, but the guides never mentioned `--on-error continue`. |
| T1.5 | `install-ingress-nginx`, `expose-a-service-with-ingress` | The example instance name `ingressNginx` became the name of its Deployment, Service, and IngressClass (`ingress-nginx/default.nix:230,241`). Kubernetes requires lowercase names, so the example could evaluate but not be applied. The package already declares `meta.defaultAliases = [ "ingressNginx" ]`, allowing the instance itself to use a lowercase name. |

The second audit downgraded T1.4, concerning stateful migration. The guide
already described the replacement gate accurately, and `--prune` asks for
confirmation unless `--yes` is present (`deploy.rs:37-52`). The remaining gap
was narrower: removing a stateful resource without a replacement creates an
ordinary orphan (`migrate.rs:218-222`). A CI run using `--prune --yes` deletes
it without a stateful migration gate. `prunable()` excludes only
`Lifecycle::Record` (`lifecycle.rs:53-57`).

### Tier 2: wrong, reader gets a broken result

| ID | Defect |
|---|---|
| T2.1 | Two guides confused `cluster.domain`, the public base domain, with `clusterDomain`, the in-cluster DNS suffix. At the time, `cluster.domain` was also undeclared and failed evaluation on a kind cluster. |
| T2.2 | The flavor guide used a cluster function taking `{ kix, flavor, ... }`, but `mkFlake.nix:62-90` passes only supported arguments from `{ kix; packages; pins; }`. The example could not evaluate. |
| T2.3 | Both dependency-debugging guides proposed an explicit `deps` override as the complete remedy for an ambiguous provider. Phase 1 suppresses those overrides (`cluster.nix:223,246-250`) and reports the ambiguity before the consumer override is read. |
| T2.4 | The graph guide listed `deps` as an edge source. `kix graph` reads edges from rendered manifests and explicit resource requirements, not from dependency injection alone (`graph.rs:30`). |
| T2.5 | `kix check --sarif` could not include error-severity scorecard findings. Those findings became failed assertions (`scorecard.nix:373-406`), and the evaluation-failure path emitted an empty SARIF run with exit status 1 (`check.rs:264-266`). **Product bug.** |
| T2.6 | The Markdown diff report always contains a heading (`plan.rs:523-541`), so checking whether the report file was empty caused CI to post a comment on every run. The exit status is the correct predicate. |
| T2.7 | `mergeFragments` rejects every duplicate leaf, even when both values are equal. The guide incorrectly said only differing values caused a conflict. |
| T2.8 | `kix inspect` prints a resource inventory, not package parts, dependencies, and outputs (`cli.rs:769-772`). The guide contradicted the command output shown on the same page. |
| T2.9 | The monitoring guide omitted the `specialArgs` needed to make `packages` available to modules (`cluster.nix:36-44`). It also recommended setting only `monitoring.grafana.persistence.size`, which fails with `attribute 'enabled' missing` because `persistence` is one unstructured option. |
| T2.10 | Smaller errors included using a bare port instead of `:80` with `kix pf`, omitting the cluster argument from `kix logs`, overlooking the two Kix CRDs in an exit export, describing `--force` as replacement when it left stale files, and allowing the CLI cluster name to differ from `buildCluster.name` even though this breaks cluster-state commands. |

### Tier 3: departures from Kix conventions

- `create-a-local-package.mdx`, a likely starting point for readers, uses a
  mutable image tag without `kix.options.image` or a pin file. This contradicts
  BEST-PRACTICES §9.4 and §12.11. Digest pinning appears in the health-check
  helper, but not in the example readers are most likely to copy.
- `provision-persistent-storage.mdx:14` presents dependency-injected storage as
  a recommendation. It is a requirement: application packages that create
  their own PVC fail evaluation (`validators.nix:209-221`).
- The stateful-migration fixture holds `meta.unsafe = [ "raw-pvc" ]` with a
  hardcoded `storageClassName`, and no page shows or mentions it. `meta.unsafe`
  appears in no how-to page at all.
- `metrics-package.nix:36-40` builds `out.endpoint` from a ConfigMap's
  `out.fqdn`, even though ConfigMaps have no network address. Kix derives
  `out.fqdn` for every namespaced resource regardless of kind
  (`resource.nix:404-409`). This does not corrupt network-policy facts because
  `_isEndpointProducer` requires a Service with a selector
  (`resource.nix:366-381`).
- The network-policy guide does not explain that using an address output such
  as `out.fqdn` derives an egress rule, while using `out.name` creates only a
  dependency edge.
- The metadata guide describes `meta.scope` as descriptive, but Kix enforces it
  by rejecting cross-namespace dependencies (`instance.nix:222-235`).
- `docs/nix/captures.nix` jq projections invent `podLabels` and a bare
  `metadata.readiness`, presented as `kix build --output json` output, on pages
  whose subject is comparing those exact paths against a live object. The
  paths do not exist, despite the "Output excerpt" label.

### Tier 4: systemic

- 19 of 87 pages carry unverified hand-written blocks (see above).
- The examples are not schema-validated or scorecard-checked.
- Five guides are live as 4-line stubs with `description: TODO`, in the
  autogenerated sidebar, one of them linked from
  `list-clusters-and-packages.mdx:58`. Tracked as `planned` and deliberately
  permitted by `check-how-to-coverage.mjs:50-54`. Across the site, 180 pages
  have `description: TODO`, mostly under `reference/`. **Decision: leave
  as-is for now.**
- `docs/flake.lock` pinned kix-examples to
  `refs/heads/docs/how-to-application-scenario`, with PR #1 open since
  2026-09-09, so the published guides depended on an unmerged branch. Fixed
  in phase 2: the PR is merged and the lock follows the default branch.

## Product bugs surfaced

The review also exposed product defects that required code changes:

| Bug | Location | Status |
|---|---|---|
| Error-severity scorecard findings never reach SARIF (empty run + exit 1) | `check.rs:264-266` | Fixed in `84effbd`. SARIF now contains one error result, attributed to the rule when the message identifies it. |
| `--prune-mode eager` claims interleaving that does not exist | `cli.rs:438,507`; `deploy.rs:727-731` | Removed in `fc3c512`. Actual interleaving requires scheduler changes and is tracked in ROADMAP. |
| `kix export --for exit` includes both Kix CRDs; `--force` leaves stale files | `export.rs:64-73,84-90` | Directory replacement was fixed in `84effbd`, with a guard that permits deletion only of an export-shaped YAML tree. The CRDs remain part of the export and are now documented. |
| No Kubernetes object-name validation in `kix/lib` or `cli/` | absent | Fixed in `254f64a`. The validator immediately found camel-case instance names in two repository examples. |
| `isValidSeverity` and `isValidLevel` are defined but unused | `scorecard.nix:10-19` | Fixed in `84effbd`, including validation of all three severity override channels. |
| `cluster.domain` is read in two places but declared nowhere | `compose.nix:955`, `monitoring.nix:219-222` | Fixed in `a85fea8`. Kix now declares the option, ludo no longer declares it locally, and the multi-environment example is included in routine builds. |
| Cluster-state commands filter Activations by CLI name, while the label uses `buildCluster.name` | `activation.rs:107-116` vs `core/activation.nix:92-94` | Open. The how-to now requires the names to match. A product fix needs a decision about which name defines cluster identity. |
| The phase-1 dependency pass cannot use explicit `deps` | `cluster.nix:223`; already documented in BEST-PRACTICES §8.4 | Open by design. Both dependency-debugging guides now explain the required alias workaround. |

The fixes exposed two additional problems:

| Bug | Status |
|---|---|
| treefmt reformatted region extracts under `docs/src/snippets/**`, which must remain byte-identical to their sources | Fixed in `c159411`. The formatter had also reported syntax errors for 39 non-standalone excerpts on every commit. |
| `clusters/test-fragments.nix` used the reserved `kix.run` domain for example platform labels | Fixed in `a85fea8`. This problem predated the audit. |

## Upstream sources of error

Several how-to errors came from older repository documentation. Those sources
also needed correction:

- `HANDBOOK.md:815,887` sets `cluster.domain` in a plain `buildCluster` with no
  declaration and says `out.fqdn` uses it. This is the likely source of T2.1.
- `cli.rs:438,507` ("eager (interleave)") is the origin of T1.1.
- `cli.rs:688-689` ("or a bare `REMOTE`") is the origin of the `kix pf` error.
- `HANDBOOK.md:1269` advertises `--skip-import-checks`, which does not exist.
- `cli/README.md:165` describes the pin scan as `pins.nix` / `*pins.nix` with a
  ``Managed by `kix pin` `` marker; the code scans `pins.json` / `*pins.json`
  for `"managedBy"` (`locate.rs:205-215`). CLAUDE.md names this file as the
  primary reference for LLM work on the CLI, making this error especially
  likely to spread.

## What would have caught what

Different checks cover different classes of error:

| Mechanism | Would have caught | Would NOT have caught |
|---|---|---|
| kubeconform in the capture sandbox | Schema errors such as unknown fields and invalid types | **T1.5.** `ObjectMeta.name` is an unconstrained string in the Kubernetes OpenAPI schema. |
| Object-name validator in `scope/validators.nix` | T1.5 during evaluation, for every user | Prose claims |
| Server-side dry-run as a capture step | T1.5 and any admission-level error | prose claims |
| Scorecard enabled in the example clusters | T3.3 (`unsafeGrants`) and missing probes or resource settings | Prose claims |
| Fenced-block count in the coverage checker | Makes the remaining unverified examples visible and measurable | Whether the example or its explanation is correct |

The object-name validator belongs in the compiler rather than only in the
documentation pipeline, because every user benefits from the earlier error.

## Corrections to the first review pass

The second audit removed four false positives from the first review:

- `extraDeps`: the doc says exactly what the code does. The reviewer reported
  the doc's own caveat as a defect.
- mkEnv `ref`: neither the page nor the example uses `ref` in an instance set.
  `env.nix:48-51` passing `ref = { }` is a library quirk the doc never touches.
- Velero `credentials`: recommending `secretContents` would put AWS keys in the
  Nix store. The documented `secretName` and `mkSecretRef` approach is correct.
- A miscitation of BEST-PRACTICES §8.4 as "prescribing the opposite" of the
  dependency guides. §8.4 recommends `deps.<arg> = ref...`; the guides omitted
  its phase-1 caveat. T2.3 remains an omission, not a contradiction.

The second audit also narrowed several findings, including T1.4 and issues
reported in the logs, hostPath, overlay, and receipt guides.

The first review also claimed schema validation would have caught T1.5. It
would not, because the Kubernetes schema does not constrain `metadata.name`.

## Plan

The work was divided by destination. Phases 0, 1, and most of 4 landed on
2026-09-16. Phases 2 and 3 remain blocked by work outside this repository.

**Phase 0, cluster safety in `docs/`:** T1.1, T1.2, T1.3, the narrowed T1.4,
the `kix pf` port fix, and a caution on platform intents (a Cilium policy
selecting an endpoint puts it in default-deny for the directions it specifies,
so an intent restricts rather than permits; `to`/`from` are a closed vocabulary
that rejects unknown values).

**Phase 1, broken-as-written, `docs/` prose:** T2.1 through T2.4, T2.6 through
T2.9, the T2.10 clauses, T3.2, T3.5, T3.6, the Tier-3 minor clauses, plus the
HANDBOOK and `cli/README.md` fixes from "upstream sources" above.

**Phase 2, kix-examples PR, lock update, and regenerated captures:** T1.5
(rename the instance lowercase), T2.9A (move `specialArgs` inside the region),
T3.4 (fix or drop the fabricated endpoint), T3.3 (characterise the `raw-pvc`
fixture). Merge PR #1 so the lock stops pointing at a branch.

**Phase 3, `docs/nix/captures.nix`:** T3.7 jq projections to real paths, the
health-check capture group ordering (the success capture runs against an
unchanged instance so the Job never appears).

**Phase 4, product:** the items under "Product bugs surfaced". The object-name
validator came first because it prevents T1.5 for every user. The phase-1
ambiguity limitation remains open because it requires a design change.

**Pipeline work:** count hand-written Nix blocks in
`check-how-to-coverage.mjs`; convert the most important blocks to checked
region snippets; enable the scorecard in example clusters through a shared
module; and validate scorecard levels and severities when loading rules.

### Phases 2 and 3, landed 2026-09-16

**Phase 2** (`3abd392` in kix-examples, `239c1ec` here). The four example
fixes went in, PR #1 merged as `3b0a04e`, and `docs/flake.lock` moved off the
branch it had been pinned to since 9 September. All 31 example clusters
evaluate against the new name validator; the `ingressNginx` instance was the
only thing it refused. The three guides that named that instance now explain
the mechanism rather than the old name: the instance is lowercase because a
package names its resources after it, and `meta.defaultAliases` is what keeps
the dependency resolving.

Two things the rename surfaced. The published ingress capture had been showing
object names Kubernetes would reject, so the fix reached the rendered output
and not only the source. And the `monitoringStack` region had excluded the
`specialArgs` line that makes the module resolve, so the snippet a reader
copies omitted the one line they needed.

**Phase 3** (`37b0b71`). Six jq projections reshaped their input rather than
excerpting it, three of them on pages that tell the reader to compare what
they see against a live object at a named path. Every key now sits where it
sits in the real output.

The health-check group's success capture contained no Job. It deployed a
cluster that earlier live groups had already deployed unchanged, so the probe
correctly did not re-run. The group now resets the cluster, which fixes the
capture and makes `--group` reproduce a full run. A fresh-cluster first deploy
logs an apiserver 429 retry, stable across runs and left in as real output.

### What remains

- **Two design questions**, not implementation gaps: which name defines
  cluster identity (`activation.rs:107-116` vs `core/activation.nix:92-94`),
  and whether the phase-1 pre-pass can be taught to see explicit `deps`
  (`cluster.nix:223`). Both are documented as cautions in the guides.
- **Snippet conversion**: 41 hand-written nix blocks across 19 pages have a
  tracked count (`1fc70c6`) and a checker that fails when it moves
  unannounced. Converting them to checked snippets is the durable half of
  this work, a page at a time.
- **Scorecard in the example clusters**, the one pipeline item from the plan
  that did not land. It would close T3.3 mechanically and stop `check.json`
  reading "scorecard skip" on the pages that teach the scorecard.

## Open questions

1. **Should `planned` mean "not published"?** Today it means "published with a
   TODO description". Starlight's `draft: true` would hide them while keeping
   the ledger entry. Deferred, but the 180 sitewide `description: TODO` pages
   make this a site-wide question, not a how-to one.
2. **Should the TLS and cluster-issuer surface be documented?** `kix.expose`'s
   `clusterIssuer` dep (`compose.nix:904,938,1060`) is documented nowhere, and
   the two stubs that would cover it are empty.
3. **How much live capture coverage is worth the cost?** Only 3 of roughly 30
   captures in the platform and package guides are live. Server-side dry runs
   would provide useful coverage, but require a kind session for groups that
   currently run offline.
4. **Should this audit be repeated elsewhere?** The review found roughly 30
   real defects and 4 false positives in 6,500 lines. The `reference/` and
   `explanation/` sections have not received the same treatment and contain
   158 of the site's 180 TODO descriptions.
