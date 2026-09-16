# 142: How-to docs accuracy audit and the verification gap

**Status:** Analysis / Accepted (findings audited, fixes not yet landed)
**Related:** `135_validation_layers_audit.md` (same question one layer down: what
validation actually runs), `docs/README.md` (snippet + capture pipeline)

## Context

`docs/src/content/docs/how-to/**` is 87 guides, about 6,500 lines, written by
Codex between 2026-09-09 and 2026-09-14 across roughly 40 commits. Nobody had
read them. This doc records what a review found, what an adversarial audit of
that review then corrected, and what the whole episode says about the docs
pipeline.

Method: five category reviewers over the whole corpus, each required to verify
every API and behaviour claim against `kix/lib/` or `cli/` rather than against
memory, then a Fable audit pass instructed to hunt for false positives in the
result. Three Nix-semantics questions were settled by running `nix eval`, not by
reading code. Raw per-finding citations live in the fix PRs; this doc keeps the
analysis.

Headline: the prose quality is high and the kix philosophy is mostly respected.
No invented spec keys, no Helm transliteration, `root` discipline clean
throughout, secrets routed through `mkSecret`/`mkSecretRef` everywhere, monitor
selectors sourced from the Service. What went wrong is accuracy, and it is
concentrated in one place with a structural explanation.

## The verification gap

The docs pipeline is better than most. Snippets are region-extracted from real
`.nix` files (`docs/nix/snippets.nix`), command output is captured from real
runs (`docs/nix/captures.nix`), offline captures are drift-gated in CI, and
`check-how-to-coverage.mjs` keeps a ledger honest against the content tree.

None of that touches three things:

1. **Prose claims.** "Kix reports the number of scorecard errors" is a sentence.
   Nothing checks sentences. Most confirmed findings are sentences.
2. **Hand-written fenced blocks.** 19 of 87 pages carry raw ```nix or ```yaml
   blocks that no derivation ever evaluates. Nearly every finding where a reader
   would hit an eval error lives in one.
   `select-and-configure-a-cluster-flavor.mdx` has exactly two such blocks and
   both are broken.
3. **Whether the examples would actually apply.** Every `check.json` in the
   corpus reads `kubeconform pass (skipped, not installed)` and `scorecard skip
   (not enabled in cluster definition)`. Of roughly 30 captures in the
   platform/package set, 3 are `generator: "live"`. The rest are eval-only.

So the harness proves the code in a snippet parses and that a command produced
the bytes shown. It does not prove the surrounding paragraph is true, that a
block the author typed by hand evaluates, or that the manifests would be
accepted by an API server.

**The generalisable lesson.** An AI writer working against a partial harness
produces prose that is confidently wrong exactly where the harness does not
reach, and confidently right where it does. The distribution of defects here is
not random: it tracks the boundary of what is checked. That boundary is the
thing to move, not the individual sentences.

## Findings inventory

### Tier 1: would break or destroy something

| ID | Page | Defect |
|---|---|---|
| T1.1 | `deploy-with-dry-run-...` | `--prune-mode eager` is shown standalone as an *ordering* choice after `--prune` was taught as the delete opt-in. `deploy.rs:727-731` maps `Eager => Delete`. The interleaving it promises does not exist: `Eager` appears twice in the whole CLI, as the variant and that one mapping. |
| T1.2 | `preserve-existing-selectors`, `preserve-helm-compatible-labels` | Both prescribe `kix diff` as the pre-takeover safety check on an immutable selector. The live side lists only `app.kubernetes.io/managed-by=kix` (`fetch.rs:66,321`), so an unadopted object is absent and renders as an addition. The check cannot fire. `take-ownership-of-kubectl-managed-resources.mdx:62` states the limitation correctly, so the directory contradicts itself. |
| T1.3 | three takeover pages | "Review the named fields" before `--force-conflicts`, but `on_error` defaults to `stop` (`cli.rs:423`) so the run halts at the first conflict. Captures end "1 failed, 4 cancelled" and "1 failed, 6 cancelled". `--on-error continue` is never mentioned. |
| T1.5 | `install-ingress-nginx`, `expose-a-service-with-ingress` | The taught instance name `ingressNginx` becomes every object's name (`ingress-nginx/default.nix:230,241`), producing `Deployment/ingressNginx`, `Service/ingressNginx`, `IngressClass/ingressNginx`. All are lowercase-only per RFC 1123 (RFC 1035 for Service). The example cannot be applied, and both pages then say to run `kix deploy`. The stated reason for the camelCase name is also false: `meta.defaultAliases = [ "ingressNginx" ]` already covers DI, which is why `ludo/cluster-kind.nix:61` uses lowercase. |

T1.4 (stateful migration) was **downgraded** by the audit. The gate's scope is
stated precisely on the page, and `--prune` does prompt y/n unless `--yes`
(`deploy.rs:37-52`), with orphans printed as "will be deleted". What remains
true and worth a sentence: a removal with no replacement is an ordinary orphan,
not a migration pair (`migrate.rs:218-222`), and `--prune -y` in CI deletes it
with no stateful-aware gate. `prunable()` excludes only `Lifecycle::Record`
(`lifecycle.rs:53-57`).

### Tier 2: wrong, reader gets a broken result

| ID | Defect |
|---|---|
| T2.1 | `cluster.domain` used where `clusterDomain` is meant, in two guides. Eval-confirmed: `cluster.domain` on a kind-flavored cluster fails with "The option `cluster.domain' does not exist". In the Cloudflare guide it also corrupts the tunnel origin, since `cluster.domain` is conventionally a public domain (`example-multi-env/prod.nix:25` = `"example.com"`). |
| T2.2 | The flavor guide's multi-environment shape `{ kix, flavor, ... }:` cannot evaluate. `mkFlake.nix:62-90` passes `intersectAttrs (functionArgs fn) { kix; packages; pins; }`. |
| T2.3 | Both dependency-debugging guides give an ambiguity remedy that cannot fire. Phase 1 runs with `explicitOverrides = { }` (`cluster.nix:223,246-250`) and is forced at `resolve.nix:322-326` before any consumer override is read. |
| T2.4 | `kix graph` draws no edges from `deps`; `graph.rs:30` builds from manifests, so edges come from string context plus `requires`. The page lists `deps` twice as an edge source. |
| T2.5 | `kix check --sarif` can never contain an error-severity finding. Error findings become failed assertions (`scorecard.nix:373-406`) that throw during eval, so `check.rs:264-266` emits an empty SARIF run with exit 1. **Product bug.** |
| T2.6 | The Markdown diff report is never empty; `plan.rs:523-541` always writes the `### kix diff` heading. The guide's "post only when non-empty" CI ergonomic comments on every run. Correct predicate is the exit code. |
| T2.7 | `mergeFragments` throws on any duplicate leaf, not on differing values. `fragments.nix:5-15` never compares them. |
| T2.8 | `kix inspect` shows a resource inventory, not parts/deps/outputs (`cli.rs:769-772`), contradicting the capture on the same screen. |
| T2.9 | Monitoring guide: `mkFlake` does not supply `packages` to modules (`cluster.nix:36-44`), and the example's `specialArgs` line sits outside the snippet region. Separately, eval-confirmed: `monitoring.grafana.persistence.size` alone fails with `attribute 'enabled' missing`, because `types.anything` deep-merges between *definitions* and a default is not a definition. |
| T2.10 | Smaller: `kix pf` bare port does not pick a free local port (needs `:80`); `kix logs cloudflared` omits the required cluster arg; the "neutral" exit export still ships both `kix.run` CRDs; `--force` merges rather than replaces; a CLI alias differing from `buildCluster.name` silently breaks every cluster-state command. |

### Tier 3: non-kixy drift

The purist question came out better than expected. Confirmed drift:

- `create-a-local-package.mdx`, the file every reader copies first, teaches a
  bare mutable image tag with no `kix.options.image` and no pin file, in the
  repo whose BEST-PRACTICES §9.4 and §12.11 argue against exactly that. The
  health-check helper pins by digest, so the right shape appears only where a
  reader cannot copy it.
- `provision-persistent-storage.mdx:14` presents a hard rule as a benefit. A
  package emitting its own PVC is an eval error (`validators.nix:209-221`).
- The stateful-migration fixture holds `meta.unsafe = [ "raw-pvc" ]` with a
  hardcoded `storageClassName`, and no page shows or mentions it. `meta.unsafe`
  appears in no how-to page at all.
- `metrics-package.nix:36-40` fabricates `out.endpoint` from a **ConfigMap's**
  `out.fqdn`, an address that resolves to nothing. `out.fqdn` is auto-derived
  for every namespaced resource regardless of kind (`resource.nix:404-409`).
  Cleared on the netpol half: `_isEndpointProducer` requires a selector-bearing
  Service (`resource.nix:366-381`), so no false endpoint fact is minted.
- The netpol guide never states the naming-versus-dialing rule, which is the one
  thing that silently breaks the feature (`out.name` opens no egress hole).
- `meta.scope` is listed among fields that "describe the package" and is a hard
  throw on cross-namespace deps (`instance.nix:222-235`).
- `docs/nix/captures.nix` jq projections invent `podLabels` and a bare
  `metadata.readiness`, presented as `kix build --output json` output, on pages
  whose subject is comparing those exact paths against a live object. The
  canon's first DSL rule is "don't invent new fields". Softened by the "Output
  excerpt" badge, but the paths shown do not exist.

### Tier 4: systemic

- 19 of 87 pages carry unverified hand-written blocks (see above).
- Examples never schema-validated or scorecard-checked (see above).
- Five guides are live as 4-line stubs with `description: TODO`, in the
  autogenerated sidebar, one of them linked from
  `list-clusters-and-packages.mdx:58`. Tracked as `planned` and deliberately
  permitted by `check-how-to-coverage.mjs:50-54`. Sitewide 180 pages carry
  `description: TODO`, mostly `reference/`. **Decision: leave as-is for now.**
- `docs/flake.lock` pins kix-examples to `refs/heads/docs/how-to-application-scenario`;
  PR #1 has been open since 2026-09-09. The whole published corpus is backed by
  an unmerged branch.

## Product bugs surfaced

Writing the docs functioned as a test suite and found real defects. These need
code, not prose:

| Bug | Location |
|---|---|
| Error-severity scorecard findings never reach SARIF (empty run + exit 1) | `check.rs:264-266`, by design per `:159-163` |
| `--prune-mode eager` claims interleaving that does not exist | `cli.rs:438,507`; `deploy.rs:727-731` |
| Cluster-state commands filter Activations by CLI name; the label carries `buildCluster.name` | `activation.rs:107-116` vs `core/activation.nix:92-94` |
| `kix export --for exit` ships both kix CRDs; `--force` does not clear the directory | `export.rs:64-73,84-90` |
| No DNS-1123 name validation anywhere in `kix/lib` or `cli/` | absent |
| `isValidSeverity` / `isValidLevel` defined and never called, so a typo'd severity silently downgrades an error rule | `scorecard.nix:10-19` |
| `cluster.domain` read defensively in two places but declared nowhere | `compose.nix:955`, `monitoring.nix:219-222` |
| Phase-1 ambiguity pre-pass cannot see explicit `deps` | `cluster.nix:223`; already documented in BEST-PRACTICES §8.4 |

## Upstream sources of error

Three doc defects are faithful reproductions of wrong text that already existed.
Fixing only the how-to leaves the trap for the next writer, human or agent:

- `HANDBOOK.md:815,887` sets `cluster.domain` in a plain `buildCluster` with no
  declaration and says `out.fqdn` uses it. Almost certainly the origin of T2.1.
- `cli.rs:438,507` ("eager (interleave)") is the origin of T1.1.
- `cli.rs:688-689` ("or a bare `REMOTE`") is the origin of the `kix pf` error.
- `HANDBOOK.md:1269` advertises `--skip-import-checks`, which does not exist.
- `cli/README.md:165` describes the pin scan as `pins.nix` / `*pins.nix` with a
  ``Managed by `kix pin` `` marker; the code scans `pins.json` / `*pins.json`
  for `"managedBy"` (`locate.rs:205-215`). CLAUDE.md names this file as the
  primary LLM reference, so it is the highest-leverage stale doc in the repo.

## What would have caught what

Worth being precise, because the obvious answer is wrong:

| Mechanism | Would have caught | Would NOT have caught |
|---|---|---|
| kubeconform in the capture sandbox | schema errors: wrong field names, wrong types | **T1.5.** `ObjectMeta.name` is an unconstrained string in the K8s OpenAPI schema. |
| DNS-1123 validator in `scope/validators.nix` (~10 lines) | T1.5, at eval, for every user and not just the docs pipeline | prose claims |
| Server-side dry-run as a capture step | T1.5 and any admission-level error | prose claims |
| Scorecard enabled in the example clusters | T3.3 (`unsafeGrants`), probe/resource omissions, and it stops `check.json` reading "scorecard skip" on the very pages that teach the scorecard | prose claims |
| A fence-block rule in the coverage checker | forces an explicit `unverified` marker where a reviewer sees it; does not itself evaluate anything | the claim inside the block |

The validator is the real "automation over brevity" fix and should land before
the dry-run step: it moves the check from the docs pipeline into the compiler,
where every user benefits.

## Corrections to the first review pass

Recording these because the review's own error rate is data about how much to
trust this method.

Four findings were **false positives**, dropped:

- `extraDeps`: the doc says exactly what the code does. The reviewer reported
  the doc's own caveat as a defect.
- mkEnv `ref`: neither the page nor the example uses `ref` in an instance set.
  `env.nix:48-51` passing `ref = { }` is a library quirk the doc never touches.
- Velero `credentials`: recommending `secretContents` would put AWS keys in the
  Nix store. The doc's `secretName` / `mkSecretRef` path is the *more* kixy shape.
- A miscitation of BEST-PRACTICES §8.4 as "prescribing the opposite" of the
  dependency guides. §8.4's primary advice *is* `deps.<arg> = ref...`; what the
  pages omit is its phase-1 caveat. T2.3 survives, but as an omission rather
  than a contradiction.

Several more were overstated and downgraded (T1.4 above, plus the logs-prefix
wording, the hostPath and overlay pages, and the receipt page, all of which are
correct for what they actually say).

The lead review also asserted that schema validation would have caught T1.5.
It would not, for the reason in the table above.

## Plan

Sequenced, bucketed by where the change lands. All four buckets approved.

**Phase 0, cluster safety, `docs/` prose, one PR:** T1.1, T1.2, T1.3, T1.4-lite,
the `kix pf` port fix, and a caution on platform intents (a Cilium policy
selecting an endpoint puts it in default-deny for the directions it specifies,
so an intent restricts rather than permits; `to`/`from` are a closed vocabulary
that throws).

**Phase 1, broken-as-written, `docs/` prose:** T2.1 through T2.4, T2.6 through
T2.9, the T2.10 clauses, T3.2, T3.5, T3.6, the Tier-3 minor clauses, plus the
HANDBOOK and `cli/README.md` fixes from "upstream sources" above.

**Phase 2, kix-examples PR + `docs/flake.lock` bump, regen captures:** T1.5
(rename the instance lowercase), T2.9A (move `specialArgs` inside the region),
T3.4 (fix or drop the fabricated endpoint), T3.3 (characterise the `raw-pvc`
fixture). Merge PR #1 so the lock stops pointing at a branch.

**Phase 3, `docs/nix/captures.nix`:** T3.7 jq projections to real paths, the
health-check capture group ordering (the success capture runs against an
unchanged instance so the Job never appears).

**Phase 4, product:** the table in "Product bugs surfaced". The DNS-1123
validator first, since it closes T1.5 for everyone. The phase-1 ambiguity
limitation last: it is real design work.

**Root cause, alongside:** a fence-block rule in `check-how-to-coverage.mjs`
requiring an explicit `unverified` marker; conversion of the worst hand-written
blocks to region snippets (roughly 8 of the 19 files covers every Tier-2
finding that lives in a block); the scorecard enabled in the example clusters
via one shared module; wiring `isValidSeverity`/`isValidLevel` into rule
ingestion.

## Open questions

1. **Should `planned` mean "not published"?** Today it means "published with a
   TODO description". Starlight's `draft: true` would hide them while keeping
   the ledger entry. Deferred, but the 180 sitewide `description: TODO` pages
   make this a site-wide question, not a how-to one.
2. **Does the TLS/cluster-issuer surface get documented?** `kix.expose`'s
   `clusterIssuer` dep (`compose.nix:904,938,1060`) is documented nowhere, and
   the two stubs that would cover it are empty.
3. **Is `cluster.domain` a real option or an accident?** The library reads it in
   two places and nothing declares it. Either declare it as `nullOr str` in
   `modules.nix` or rename the reads. Until then every use is a latent eval
   error and the HANDBOOK teaches it.
4. **How much live capture coverage is worth paying for?** 3 of ~30 today. A
   dry-run step per example cluster is the cheap middle, but it needs a kind
   session in the capture pipeline for groups that currently run offline.
5. **Does this audit method generalise?** Five verifying reviewers plus an
   adversarial audit found roughly 30 real defects and 4 false positives in
   6,500 lines. Worth repeating on `reference/` and `explanation/`, which have
   had no pass at all and carry 158 of the 180 TODO descriptions.
