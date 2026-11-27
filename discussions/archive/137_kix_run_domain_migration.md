# 137: Moving Kix's Kubernetes domain from kix.dev to kix.run

**Status:** Implemented (kixpkgs#84, 2026-09-09). stage2, stage1 and lab1 all migrated the same day. The compatibility layer in `cli/kix/src/legacy_domain/` is still in place; its removal checklist is below and is referenced from `ROADMAP.md`.
**Related:** `128` (annotation domain ownership; the rule that reserves `kix.dev` as ours), `interesting_thoughts/133_cluster_readback_surface.md` (what the stamped annotations are read for), `122_runtime_content_drift.md` (`kix.dev/applied-hash`), `55_shared_resource_ownership.md` (`kix.dev/activations` as a reference set)
**Source:** Adam, 2026-09-08: "plan out a migration from the kix.dev domain in our annotations (that we don't own it), to kix.run, which we do indeed own". Revision 2 after review the same day: one PR, not four; the compatibility code lives in one place so it can stay for as long as we like and be deleted in one go; running the migration is mandatory, so a deploy against an unmigrated cluster fails and says what to run.

## The problem

Kubernetes convention says the prefix of an annotation or label key, and the group of an API, is a DNS name you control. Kix uses `kix.dev` for both, and we do not own `kix.dev`. Whoever does can publish their own `kix.dev/...` keys or an `activations.kix.dev` CRD tomorrow, and a cluster that has both would have two owners for one name. The `architecture.annotationDomainOwnership` rule from doc 128 even lists `kix.dev` among the reserved suffixes "because it is ours". We own `kix.run`.

This is a rename, but not a search and replace. The domain is written into live objects on every cluster Kix has deployed. It is the API group of two CRDs whose records hold the deploy history. And the CLI identifies resources without looking at the group.

## Inventory (2026-09-08, main at 6f3084f)

| Where | Files | Mentions | What |
|---|---|---|---|
| `kix/lib` | 18 | about 150 | Annotations stamped at eval (`depends-on`, `readiness`, `rerun`, `import-*`, `root`, `inverse-deps`, ...), the two CRDs (`core/resource.nix:548,554`, group `kix.dev`), the record `apiVersion` (`core/activation.nix:31,69`), the reserved-suffix list (`rules/architecture.nix:61`), the import-marker reads in the same rules file, tests that spell keys by hand (`tests/validate.nix`, 40 mentions) |
| `kix/packages` | 14 | 32 | `kix.dev/hook`, `hook-delete-policy`, `operand-of`, `monitors-external-service`, `sops-source` on package resources |
| `cli/kix/src` | 22 | about 140 | Every reader and every CLI-side stamp: `stamp.rs` (`identity-hash`, `package`, `package-namespace`, `lifecycle`), `apply.rs:23-32` (`IDENTITY_HASH_ANNOTATION`, `ACTIVATIONS_ANNOTATION`, `RERUN_ANNOTATION`), `fieldsv1.rs:22` (`APPLIED_HASH_ANNOTATION`), `activation.rs:24-38,279` (`previous`, `deployed-at`, `cluster` label, `built-via`), `lifecycle.rs:36` (`mode`), `readiness.rs` (34 mentions, the `import-*` and `readiness` reads), `migrate.rs` (stateful pair detection, unrelated to this plan despite the name), the Activation lookup by group (`activation.rs:70`) |
| `cli/kix-cli/src` | 14 | 56 | `health`, `gc`, `graph`, `inspect`, `deploy`, `plan.rs` reading the same keys; `operator.rs:25` group; `compliance/sbom.rs:213` vendor string; help text in `cli.rs` |
| `cli/kix-operator/src` | 2 | 8 | The informer group (`main.rs:48-50`), the finalizer `kix.dev/operator-gc` (`controller.rs:63`), the CRD names the operator's own gc protects (`controller.rs:508`) |
| `docs-legacy`, `cli/README.md`, `kix/lib/architecture.md`, `.claude/skills` | 7 | 72 | HANDBOOK (26), FEATURE-CATALOG (13), BEST-PRACTICES (5), cli/README (16), architecture.md (7), the migration skill and its SECRETS.md (5) |
| `scripts`, `demo`, `ludo` | 8 | 18 | `scripts/parity/normalize.py` strips `kix.dev/` and `build.kix.dev/` before diffing; the vhs demo tapes; a comment in `ludo/secrets/valkey.yaml` |
| `kix/libv1` | 7 | about 60 | The previous library. Referenced from no flake output. Out of scope; it keeps `kix.dev`. |
| `discussions` | 65 | 289 | History. Stays as written. |
| Lithus monorepo | 1 | 1 | `CLAUDE.kix.md` names the annotation family |

The checklist for the sweep is one command: `grep -rho 'kix\.dev/[a-zA-Z0-9_.-]*' kix/lib kix/packages cli --include='*.nix' --include='*.rs' | sort -u`. About fifty distinct keys.

Live state, from stage2: CRDs `activations.kix.dev` and `packageinstances.kix.dev`, 11 Activation records, every managed object carrying `kix.dev/identity-hash`, `kix.dev/depends-on`, `kix.dev/package`, `kix.dev/activations` and, where applied by SSA since doc 122, `kix.dev/applied-hash`. stage1, lab1 and ludo hold the same shape. fb1 is read-only for us.

## Five facts that shape the plan

1. **The CLI identifies a resource by kind, namespace and name, never by group.** `ResourceId` (`cli/kix/src/manifest/types.rs:10-14`) has three fields, and kind lookup in discovery takes the first `ApiResource` whose kind matches (`cluster/ops/kube.rs:103`; `fetch::discover_resources` is first-wins per kind). While `activations.kix.dev` and `activations.kix.run` both exist, `Activation/_cluster/stage2-24qwhigv4a8l` names two objects and the CLI cannot tell which one it read or applied. The two groups must never be live on one cluster at the same time.
2. **The previous build is re-read from the local Nix store and re-stamped by the current CLI.** `load_old_from_cluster` (`cli/kix-cli/src/commands/deploy.rs:458-560`) finds the Active record, resolves its store path locally, loads the graph, and calls `stamp_annotations` on it. The same loader serves rollback, gc and the operator (`load_and_stamp`). So the CLI-side keys on an old build already come from the running CLI. Only the eval-time keys (`depends-on`, `readiness`, `rerun`, `import-*`) are frozen in the old store path with the old domain. There is one place to fix them: the loader.
3. **Build-time annotations are replaced by server-side apply; bookkeeping annotations are not.** `identity-hash`, `depends-on`, `package` and the rest are fields of the applied manifest under field manager `kix` (`apply.rs:625`). An apply without the old key drops it, because the manager owned it. `activations` and `applied-hash` are written by a merge patch in `update_bookkeeping_annotations` (`apply.rs:594`); a rename must null the old key in the same patch or it stays on the object forever, and `kix gc` and `kix health` would read a stale set.
4. **The Activation records are the deploy history.** `kix rollback --list`, `kix rollback`, `kix gc` and the previous-activation chain (`kix.dev/previous`) read them. A new CRD group starts with zero records. The records must be copied, not recreated, or every cluster loses its rollback history on migration day.
5. **The operator holds a finalizer on every record it has reconciled.** `kix.dev/operator-gc` (`controller.rs:63`). Deleting the old CRD cascades to its records, but a record with a finalizer stays `Terminating` until something removes it, and the operator that would remove it no longer watches that group. The migration must strip the finalizer from every old record before it deletes the old CRD.

## Decision

Move everything: annotation and label keys, and the CRD group. Half a move (keys only, group stays) would leave the strongest ownership claim, the API group, on a name we do not own, and would mean two domains to explain forever.

Three rules from the review:

- **One PR.** The move lands as one pull request with three commits that are checkable one at a time (see The PR). It is squash-merged.
- **The compatibility code lives in one place and stays until we delete it.** Nothing in the plan says "for one release". Every piece of code that exists only because clusters were once deployed under `kix.dev` lives in a module named for that purpose, and the rest of the codebase calls into it through a handful of one-line hooks. Removing the compatibility layer is a checklist at the end of this document, and a test enforces that `kix.dev` appears nowhere else.
- **Migration is mandatory.** Every command that touches Activation records refuses to run against a cluster that still has the old CRD group, and its error names the one command to run. The migration is its own command, not a side effect of `kix deploy`: it deletes CRDs and rewrites history, it has a dry run that prints the copy plan, and the operator cannot run it. The gate makes it impossible to skip.

## Design

### The domain in one place

Today the domain is a string literal in about 65 files. It becomes one constant on each side, and the literal `kix.dev` survives only in the compatibility module.

**Nix.** `kix/lib/core/annotations.nix` already exists as the shared home for keys (it holds `rerun` today and is imported by `vocab/compose.nix` and `eval/validate.nix`). It grows:

```nix
{
  domain = "kix.run";
  group = "kix.run";                  # the CRD API group
  apiVersion = "kix.run/v1alpha1";
  key = name: "kix.run/${name}";      # spelled once below, not interpolated from domain, so grep finds it
  keys = { identityHash = ...; dependsOn = ...; readiness = ...; rerun = ...; hook = ...; ... };
  # Compatibility with clusters deployed under kix.dev. See discussions/137
  # and the removal checklist there. Delete this attribute when the layer goes.
  legacyDomains = [ "kix.dev" ];
}
```

Every `"kix.dev/..."` literal in `kix/lib` and `kix/packages` becomes a reference to `annotations.keys.<name>` or `annotations.key "<name>"`. The CRD builder (`core/resource.nix:548,554`) and the two record constructors (`core/activation.nix:31,69`) read `group` and `apiVersion`. The reserved-suffix list in `rules/architecture.nix:61` becomes `[ annotations.domain ] ++ annotations.legacyDomains`. `tests/validate.nix` and `tests/default.nix` read the same constants. `kix/libv1` is untouched.

**Rust.** A new module `cli/kix/src/manifest/keys.rs`:

```rust
pub const DOMAIN: &str = "kix.run";
pub const GROUP: &str = "kix.run";
pub const API_VERSION: &str = "kix.run/v1alpha1";
macro_rules! key { ($name:literal) => { concat!("kix.run/", $name) } }   // consts need a literal
pub const IDENTITY_HASH: &str = key!("identity-hash");
pub const ACTIVATIONS: &str = key!("activations");
pub const APPLIED_HASH: &str = key!("applied-hash");
pub const OPERATOR_GC_FINALIZER: &str = key!("operator-gc");
// ... every key the CLI writes or reads, about fifty

/// Read a Kix key from any object's annotations, live or loaded.
pub fn get<'a>(annotations: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    annotations.get(key).and_then(Value::as_str)
        .or_else(|| legacy_domain::fallback(annotations, key))   // hook 1
}
```

A test asserts `DOMAIN`, `GROUP`, `API_VERSION` and the macro agree. The scattered constants (`IDENTITY_HASH_ANNOTATION` in `apply.rs`, `MODE_ANNOTATION` in `lifecycle.rs`, the activation constants, `APPLIED_HASH_ANNOTATION` in `fieldsv1.rs`, `PACKAGE_ANNOTATION` in `migrate.rs`, the operator's `FINALIZER`) become re-exports of `keys::*` or are replaced at their use sites. The operator's informer (`kix-operator/src/main.rs:48-50`), the CLI's operator command (`operator.rs:25`), the synthesised records (`lifecycle.rs:180`, `operator.rs:93`) and the operator's protected-CRD list (`controller.rs:508`) build from `keys::GROUP` and `keys::API_VERSION`.

Rule for the sweep: **a read of a Kix key from a `DynamicObject` or a `Value` goes through `keys::get`; a write uses the constant.** Reads through `keys::get` are what make the compatibility layer work; a direct `.get(keys::IDENTITY_HASH)` on a live object would miss an old key. `fetch::is_stamped` (`fetch.rs:226`), the `activations` set read in gc and the bookkeeping patch, `applied-hash` in drift, the `import-*` reads in readiness, and `health` are the reads that see live objects.

**Scripts.** `scripts/parity/normalize.py` takes its prefixes from one list at the top of the file, with the `kix.dev/` entry marked as the compatibility entry. `build.kix.dev/hash` is dropped: nothing writes it.

### The compatibility module

`cli/kix/src/legacy_domain/mod.rs`, with its own tests, and nothing else in the tree spells `kix.dev`. Its header comment points here. It exports five things:

1. **`fallback(annotations, key)`.** If `key` starts with `kix.run/`, look up the same name under `kix.dev/`. Called from `keys::get` only.
2. **`upgrade_manifest(&mut Value)`.** Renames every `kix.dev/*` annotation and label key on a manifest to `kix.run/*`. Called from one place: the store-graph loader that `load_old_from_cluster`, rollback, gc and the operator's `load_and_stamp` share, right before `stamp_annotations`. After this, an old build loaded from the store looks like a new one, so `kix rollback` to a pre-move activation writes `kix.run` keys and the planner never sees an old key from a store path. It is also applied to the live projection in `reconstruct_old_from_live`, so the planner never sees an old key from the cluster either.
3. **`bookkeeping_null_outs()`.** Returns `[kix.dev/activations, kix.dev/applied-hash]`. `update_bookkeeping_annotations` and `record_activation_on_skipped` add each as `null` to the merge patch they already send. One line in each.
4. **`check(discovery, build_manifests)`.** The gate. Returns an error when `activations.kix.dev` is in discovery (old group live, migration not run), when both groups are in discovery (migration interrupted), or when the build being deployed carries an Activation or PackageInstance with `apiVersion: kix.dev/v1alpha1` (a kixpkgs pin from before the move, which would re-create the old CRD). Called from `find_activation_ar` (`activation.rs:68`), which becomes `Result<Option<..>>`; its nine callers (deploy, rollback three times, health, gc twice, status, `ops/kube.rs:96` for the operator) all pass the error up. The message:

   ```
   this cluster's Kix records use the retired kix.dev API group.
   Run once:  kix migrate domain <cluster>
   Then retry. See `kix migrate domain --help` for what it does.
   ```

   and, for the stale-pin case, "this build renders Kix's own records under kix.dev; update the kixpkgs pin".
5. **`migrate(client, cluster, crds, dry_run)`.** The migration itself. See the next section.

### `kix migrate domain <cluster>`

A new top-level command in `cli/kix-cli/src/commands/migrate.rs`, one variant in `cli.rs` and one line in `main.rs`. It evaluates the cluster build the way `kix deploy` does (same flake arguments), takes the two CRD manifests out of it, and calls `legacy_domain::migrate`. Steps, on one cluster:

1. Refuse if any old record is in phase `Deploying`.
2. Read every `activations.kix.dev` record. Print the copy plan: name, phase, deployed-at, and the counts. Under `--dry-run`, stop here.
3. Apply the two new CRDs and wait until discovery shows them.
4. For each old record, create the `activations.kix.run` record with the same name, spec, status (`phase`, `previousActivation`, `deployedAt`, the checkpoint counters), and its annotations and labels with the domain renamed. No finalizer: the upgraded operator adds its own when it first reconciles.
5. Verify: the same count, and every name present in the new group.
6. Strip `kix.dev/operator-gc` from every old record.
7. Delete `packageinstances.kix.dev` and `activations.kix.dev`. Wait until discovery no longer lists them.
8. Print what to do next: upgrade the operator image if the cluster runs one, then `kix deploy`.

PackageInstance objects are not copied. The deploy that follows re-creates them from the build (they are in every activation's manifest set), including the import markers (`mode: import`).

The command is idempotent in the failure cases that matter: run again after a crash between steps 4 and 7, it finds records already present in the new group by name, skips them, and continues. Run against a cluster with no old group, it says so and exits 0.

### What the first deploy after the move does

Every rendered manifest carries `kix.run/*`, so the identity hash of every resource changes (the sealed manifest changed). `detect_changes` finds no matching hash on the old side and marks everything `Apply`. That is one server-side apply per resource, no deletes. The apply under manager `kix` drops the old build-time keys (fact 3); the bookkeeping patch nulls the two patch-written keys (hook 3). Expected on stage2: "88 configured, 0 created, 0 deleted". This is the cost of the move and it is paid once per cluster. A second deploy is a no-op.

**Correction, found while implementing.** The first draft of this section said no workload rolls, because the keys sit on the object and not on the pod template. That is true of the keys themselves and false of one consequence. A package that hashes a ConfigMap into a pod-template annotation to force a rollout on config change puts `configmap.out.identityHash` there, and that hash covers the ConfigMap's own annotations. Move the domain and the ConfigMap's hash changes, so the pod-template annotation changes, so the pods roll. Three packages do this: `valkey`, `n8n` and `python-app`. Their pods restart once on the first post-move deploy. Nothing else does. The build diff of `cluster-example` is the evidence: every changed line is a Kix key, a Kix hash, or one of these `checksum/*` annotations.

### The operator

The operator watches one group (`main.rs:48`), and the new operator watches `kix.run`. Order on a cluster that runs one: `kix migrate domain` first, so the old operator stops seeing records and nothing reconciles, then upgrade the operator image, then `kix deploy`. The wrong order is safe too: an upgraded operator against an unmigrated cluster hits the gate in `find_activation_ar` through `ops/kube.rs:96`, logs the message each reconcile, and touches nothing. The operator's own gc reads `keys::GROUP` for the CRDs it protects (`controller.rs:508`). The operator's RBAC manifests are not in kixpkgs (the demo tapes carry them); their `apiGroups` entry is edited by hand with the tapes.

### Everything else that changes

- **Scorecard.** `rules/architecture.nix` reserves `kix.run` and, through `legacyDomains`, `kix.dev`, so a helm-imported object still carrying an old key does not warn about a dead domain.
- **Packages.** `kix.dev/hook` and `hook-delete-policy` (reflector), `operand-of` (thanos, alertmanager, VM cluster), `monitors-external-service`, `sops-source`: all through `annotations.nix`, so they flip with the constant. `kix health` reads `hook-delete-policy` from the store seal, which is rebuilt, so no live concern.
- **Docs.** HANDBOOK, FEATURE-CATALOG, BEST-PRACTICES, the migration skill and SECRETS.md, `cli/README.md`, `kix/lib/architecture.md`, the vhs tapes, the `ludo/secrets/valkey.yaml` comment, the monorepo's `CLAUDE.kix.md` line. One new HANDBOOK section, "Clusters deployed before the kix.run move", says: upgrade the CLI, run `kix migrate domain`, deploy, and what the first deploy does. Archived discussions stay.
- **SBOM.** `vendor: kix.dev` (`sbom.rs:213`) is a display string, not a key. It becomes `kix.run`.
- **Help text.** `cli.rs` mentions `kix.dev/identity-hash`, `kix.dev/activations`, `kix.dev/applied-hash` in flag help. They read the constants through `concat!` or are reworded.

## What can go wrong, and the guard for each

| Risk | Guard |
|---|---|
| Someone deploys with the new CLI before migrating | The gate. Every record-touching command fails with the message naming `kix migrate domain`. |
| Both groups live at once | `migrate domain` deletes the old CRDs in the same run. The gate refuses to run anything while both exist and says to run `migrate domain` again, which is idempotent. |
| A kixpkgs pin from before the move is deployed with the new CLI | The gate reads the build's own record `apiVersion` and refuses with "update the kixpkgs pin". Without this the deploy would re-create `activations.kix.dev`. |
| The migration crashes between copying and deleting | Rerun. Records already in the new group are skipped by name; finalizer stripping and CRD deletion are idempotent. |
| Old records stuck `Terminating` behind the operator finalizer | Step 6 strips it before step 7. A test on the fake covers a record with the finalizer. |
| A CLI built before the move runs against a migrated cluster | It finds no `activations.kix.dev` and fails with "Activation CRD not registered on cluster" (`activation.rs:42`), the same message as an empty cluster. That CLI is the one being retired, so the message is not improved. |
| A helm chart or third party writes a `kix.dev/*` key | Warns as a dead domain once `legacyDomains` is removed; until then it is reserved and silent. The right answer for a name we do not own. |
| Old keys left on objects the deploy never applies again (a resource later pruned, a hook Job that removed itself) | Harmless: `keys::get` reads them through the fallback for as long as the layer exists, and nothing reads them after. |
| The first post-move deploy on a large cluster applies every resource | It applies, it does not restart anything. The release note says so. stage2 at 88 resources takes about the time of a `--reconcile` today. |
| Lithus monorepo pin | The pin bump and the CLI upgrade land in the same nix-darwin switch. If they drift, the gate's pin check catches the old pin. |
| `kix.dev` creeps back into the tree | A test in `keys.rs` walks `kix/lib`, `kix/packages` and `cli` and fails if `kix.dev` appears outside the compatibility module, `annotations.nix`'s `legacyDomains` line, and `normalize.py`'s marked entry. Runs with `cargo test`. |

## The PR

One pull request, three commits, each checkable on its own. Squash-merged.

1. **Keys in one place, no behaviour change.** `annotations.nix` and `keys.rs` with `domain = "kix.dev"` still. Every literal becomes a reference. The `find_activation_ar` signature change and its callers. Check: the manifest trees of ludo-kind, stage1, stage2 and lab1 are byte-identical to main (content addressing makes this refactor machine-checkable, the rule from doc 126); the kix-cli snapshots are unchanged; `cargo test` and the Nix test suite pass.
2. **The compatibility module and the command, still on `kix.dev`.** `legacy_domain` with its five exports, the four hooks wired in, `kix migrate domain`. With the domain still `kix.dev` the fallback and the upgrade are no-ops and the gate never fires, so this commit changes nothing at runtime and can be reviewed for shape. Check: unit tests for `fallback`, `upgrade_manifest`, the null-outs in the patch, the gate's four cases (neither group, old only, new only, both; stale pin), and `migrate` on the scripted fake (copy, skip-existing, finalizer strip, refuse on `Deploying`, dry run); trees still identical.
3. **The flip.** `domain = "kix.run"` in both files. Snapshots regenerate (hashes and the Activation name). The HANDBOOK section. Docs and tapes. Check: the grep test passes; the live rehearsal below.

Live rehearsal, before the PR leaves draft:

1. **ludo-kind with history.** Deploy from main three or four times so there are records to copy and a `previous` chain. Then with the PR's CLI: `kix deploy` fails with the gate message. `kix migrate domain ludo-kind --dry-run` prints the copy plan. `kix migrate domain ludo-kind` copies, strips, deletes; `kubectl get crd | grep kix` shows only `kix.run`. `kix deploy`: everything configured, nothing created or deleted, no pod restarts (compare `kubectl get pods -o wide` and ReplicaSet generations before and after). Any managed object's annotations show only `kix.run/` keys. A second deploy is a no-op. `kix rollback --list` shows the full history; rollback two steps and forward again. `kix health`, `kix gc --dry-run`, `kix drift` green.
2. **Same cluster, the operator.** Start the old operator, migrate, watch it go quiet; start the new operator, watch it reconcile the new records and add its finalizer.
3. **stage2, then stage1, then lab1**, one at a time, with the record count checked before and after and the post-deploy checks from step 1. Both VictoriaMetrics probes are on for stage2, so the rerun rule from #79 is exercised on the first post-move deploy too (every probe Job's hash changed, so every probe runs).

## Removing the compatibility layer

When we decide the layer has served its purpose. One PR, one sitting:

1. Delete `cli/kix/src/legacy_domain/` and `cli/kix-cli/src/commands/migrate.rs`.
2. Remove the `Migrate` variant in `cli.rs` and its line in `main.rs`.
3. Remove the four hooks: the `or_else` in `keys::get`; the `upgrade_manifest` call in the store-graph loader and in `reconstruct_old_from_live`; the `bookkeeping_null_outs` lines in the two patch builders; the `check` call in `find_activation_ar`.
4. Delete `legacyDomains` from `annotations.nix` and the `++` in `rules/architecture.nix`.
5. Delete the `kix.dev/` entry in `normalize.py`.
6. Shrink the allowlist in the grep test to nothing.
7. Delete the HANDBOOK section, and this document's removal checklist becomes history.

After that, a cluster that was never migrated fails with "Activation CRD not registered on cluster", and the fix is to install a CLI from before the removal and run `kix migrate domain` with it.

## What this plan does not decide

- Whether `v1alpha1` becomes `v1alpha2` with the group. Nothing in the schema changes, so no. A later schema change is the time for it.
- Labels versus annotations. `kix.dev/cluster` is a label on Activation records and is renamed like the rest; no key changes kind.
- Whether `kix migrate` grows other subcommands. The name leaves room; nothing is planned.
- `kix/libv1`. It is not built by any flake output and keeps `kix.dev`. Deleting it is a separate decision.
