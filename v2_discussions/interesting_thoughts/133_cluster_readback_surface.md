# 133: Cluster read-back surface

**Status:** Brainstorm / follow-up capture
**Relevance:** Future, except where noted (two items belong in `ROADMAP.md`, see §6)
**Related:** `55_shared_resource_ownership.md` (its stated precondition changed, see §3), `129_scaling_axes_fleet_and_linking.md` (activation slicing), `cli/README.md`

---

## 0. Why this doc exists

Three bugs were fixed on 2026-07-26 (all shipped and verified on the live ludo
cluster). While fixing them, five follow-ups surfaced that were out of scope.
This is the handoff so they are not lost.

What shipped:

1. **`kix.untrackedRef` markers no longer leak into `kix.dev/depends-on`.**
   The marker is an inert `builtins.toFile` whose only job is to give a
   deliberately-untracked name enough string context to clear
   `checkNamespacedRefs`. There is no resource behind it, so stamping its hash
   produced an edge nothing could resolve. Minting plus the `isUntrackedRefPath`
   predicate now live in `kix/lib/core/markers.nix`; the stamper in
   `core/resource.nix` filters that channel out alongside fact tokens.
   Regression test `t45-untracked-ref-not-a-dep`.

2. **`kix health` treats a completed, reaped hook Job as satisfied.**
   `declares_own_deletion()` in `commands/health.rs` reads the absent
   dependency's seal back from the local nix store and, when the manifest
   declares its own deletion (`hook-succeeded` delete policy, or a Job's
   `ttlSecondsAfterFinished`), records `ResourceHealth::Reaped` instead of
   `Missing`.

3. **`kix.dev/activations` no longer under-counts.** Skipped resources are now
   stamped in a best-effort pass after every node is terminal
   (`apply::record_activation_on_skipped`), and `merge_activation_set()` prunes
   entries naming an Activation CR that no longer exists. Measured on ludo:
   28/53 stale before, 0/187 after.

The common thread across the follow-ups: **Kix stamps four annotations onto
live resources (`identity-hash`, `depends-on`, `activations`, `applied-hash`)
and several consumers read them back without a build.** Every item below is a
weakness in that read-back path.

---

## 1. Seal-path parsing is ambiguous (confirmed bug)

`resolve_hash_to_rid()` in `commands/health.rs` recovers a resource identity by
string-splitting the seal's store-path name, `k8s-<Kind>-<ns>-<name>`, with
`splitn(4, '-')`. Namespaces and names both contain hyphens, so the encoding is
ambiguous and the parse is wrong whenever the namespace has one:

```
k8s-Deployment-monitoring-system-grafana
  → kind=Deployment, namespace=monitoring, name=system-grafana
```

Verified against a real store path
(`/nix/store/3dm0q40b…-k8s-Deployment-monitoring-system-grafana`).

Display-only: matching is by hash, so nothing mis-resolves, but health prints a
confidently wrong resource name. It stayed hidden on ludo because both reaped
Jobs live in namespace `data`. Three of ludo's six namespaces are hyphenated,
so one TTL'd hook in `monitoring-system` surfaces it.

No splitting scheme fixes an ambiguous encoding. The fix is to stop parsing the
path: `read_seal()` already exists (added for item 2 above), so take
kind/namespace/name from the manifest JSON and fall back to the path parse only
when the seal is unreadable. Small and contained.

## 2. Ephemerality should live in the annotation, not the local store

This is the honest weakness in what shipped. `declares_own_deletion()` reads
the seal from the **local** nix store, so it works on the machine that built
the activation and degrades to the old MISSING behaviour anywhere else, or
after `nix-collect-garbage`. The dependence was inherited from
`resolve_hash_to_rid()` and then leaned on harder.

The durable design is to tag the edge at eval time: stamp `ephemeral:<hash>` in
`kix.dev/depends-on` when the dependency is a Job that declares its own
deletion, alongside the existing bare / `requires:` / `extra:` tags. Health then
needs no store at all, and the same signal becomes readable by the operator and
by CI.

Cost: a manifest content change, which is why the CLI-side fix went first.
Complication: implicit (context-derived) depends-on entries only carry a store
path at stamp time, so the kind is not known without reading the dep's seal,
which the comment at `core/resource.nix` flags as a fixpoint hazard. Deps
arriving via `requires`/`extraDeps` do carry the full resource attrs and are
easy. A first cut could tag only those and leave implicit entries alone, since
the two real cases on ludo (`postgres-reflect`, `immich-db-bootstrap`) are
post-deploy hooks.

## 3. The activations set: doc 55's precondition, and a second gap

`55_shared_resource_ownership.md` §"Next" says reference-counted cleanup
"requires the annotation to be reliable". **For the single-cluster case that is
now true**, which unblocks the biggest open item in 55. Two corrections to that
doc's current state section: the function is now
`update_bookkeeping_annotations` (not `update_activations_annotation`), and its
claim that the annotation "already tracks which activations reference each
resource" was false until 2026-07-26.

Nothing consumes the set yet. `gc.rs` still decides deletions from
`expected_hashes`, which requires a nix eval. Making it trustworthy was the
precondition for the open ROADMAP item "`kix gc` without cluster eval": a
resource whose activation set goes empty after superseded cleanup is garbage,
provable from the cluster alone.

**The second gap, which 55 does not know about.** Pruning is keyed on "does
this hash name a live Activation CR", not "does that activation still contain
this resource". Take 55's own scenario: Team A and Team B both reference the
cert-manager CRDs. Team A stops referencing them but Team A's activation stays
alive. A's hash is never removed from the CRD, because no deploy touches a
resource it no longer contains.

So the set is an **upper bound on referencing activations, not an exact count**.
That fails safe (a resource is retained when it could have been collected, never
deleted while referenced), but ref-counted cleanup built on it would leak.

Fixing it properly means the prune authority is not "which Activations exist"
but "which Activations still list this resource", which needs the activation to
carry its resource set, or an inverted index. Worth designing before anything
deletes based on the count. Note `129`'s activation slicing may dissolve this by
making single-owner the rule.

## 4. The stamping pass costs N GETs

`record_activation_on_skipped` does a GET (to read-modify-write the set) plus a
conditional PATCH per unchanged resource, on every activation-hash change. 167
GETs on ludo, which is nothing, but it scales with cluster size.

Two easy wins, neither taken yet:

- The operator path already fetched every live object in
  `detect_changes_live()` and discards it. Threading those through removes the
  re-read entirely.
- The CLI path (`detect_changes`, diffing against old manifests) has no live
  objects, but could do one LIST instead of N GETs.

The no-write optimisation (`merged != existing`) is in and unit-tested, but was
**not** exercised live: the second deploy short-circuited at "activation
identical to active, nothing to apply" before `run_deploy` was reached. It
matters for retries and `--reconcile`.

## 5. Housekeeping tripped over on the way

- **Two tests fail on a clean tree.** `cross_package_edge_is_collapsed_to_pi`
  asserts the cross-package edge collapse that `graph.rs` explicitly documents
  as DISABLED (it caused cycles). `list_clusters` invokes `kix list` with no
  subcommand, which the CLI now requires. Fix or `#[ignore]` with a pointer to
  the re-enable plan. A permanently red suite trains people to stop reading it.
- **`kix diff <cluster>` renders every resource as `Kind/unknown`**, so the
  command is currently useless. Fell back to `deploy --dry-run` for plan
  inspection.
- **`kix/libv1` still carries the same `untrackedRef` bug** in its own copy of
  the stamper (`libv1/k8s.nix`). Nothing imports it. A divergent dead copy is
  worse than no copy; delete it.

---

## 6. Where these should land

| # | Item | Destination |
|---|---|---|
| 1 | Seal-path parse ambiguity | `ROADMAP.md` (confirmed bug, small fix) |
| 2 | Ephemerality into the annotation | here, until someone runs health off-build-host |
| 3 | Activations set: consume it, close the upper-bound gap | feeds `55`; the "consume it" half is already a ROADMAP item |
| 4 | N GETs → LIST / reuse live objects | `ROADMAP.md` (perf chore, no design needed) |
| 5 | Housekeeping | `ROADMAP.md` |

## 7. Open questions

- Item 2: is `ephemeral:` the right vocabulary, or is this an instance of a
  general "edge kind" the tag set should carry (the same slot that already
  distinguishes bare / `requires:` / `extra:`)?
- Item 3: should the Activation CR carry its full resource set so pruning can be
  exact, or does `129`'s activation slicing make the shared-resource case rare
  enough that the upper bound is fine forever?
- Does `kix health` want a `--no-store` mode that reports honestly ("cannot
  classify this absent dependency") rather than silently degrading to MISSING
  when the seal is unavailable? That is the same question as item 2 from the
  other end.
