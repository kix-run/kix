# 157: `kix plan` as the primary preview

**Status:** Implemented (2026-10-03, branch `cli/kix-plan`). Sections 1 to 4 shipped: `kix plan`, `kix deploy` printing the plan and stopping before it applies a refused write, `kix deploy --dry-run` as an alias, the typed `Plan` document with its committed schema and agreement tests, and three-way labels. Section 5 (saved plans) and section 6's in-cluster execution did not; they and the remaining open questions are in `ROADMAP.md § Open design questions` ("`kix plan`, what doc 157 left open"). Answers given while implementing: a webhook without dry-run support is a `not_checked` object, not an error (Q2); unchanged objects skip the dry run because the engine skips them (Q3); Secret values are hidden in the field changes, both renderers, and drift values (Q4); without the deployed build nothing is labelled and drift is `not_checked` (Q5); `NotChecked` carries a reason (Q6). The shipped JSON names the refusal section `admission` and also files non-admission refusals there with a `reason`, and adds a third label, `drift_kept`, for drift on an object the deploy does not apply.
**Related:** `111_operator_experience.md`, `122_runtime_content_drift.md`, `81_deploy_as_lifecycle_engine.md`, `64_init_and_ci_concerns.md`, `62_operator_production_implementation_plan.md`, `cli/kix-cli/src/commands/diff.rs`, `cli/kix-cli/src/commands/deploy.rs`, `cli/kix-cli/src/plan.rs`

## Problem

Kix has two ways to preview a deploy, and neither is the whole answer.

- **`kix diff`** compares the build with something it can read: the live
  cluster's kix-owned view (read-only, `get` and `list`), a snapshot, or
  another build (`--from`). It lists field changes. It cannot see what only
  happens on the write path: admission webhooks that refuse or mutate an
  object, field ownership conflicts with another manager, and the deploy's
  own refusals, such as stateful migration pairs.
- **`kix deploy --dry-run`** runs the real deploy pipeline with
  `dryRun=All`, so the API server answers for every write. It sees those
  refusals, but it reports one verb per object (created, configured,
  unchanged) and no field changes.

On 2026-10-03 a deploy of the Lithus `kix-enterprise-test` cluster on stage1
showed the gap. `kix diff` listed the changes; the deploy then stopped three
times on things the diff never mentioned: a migration pair (one of them a
ConfigMap pair with no data), a `kubectl scale` that owned
`spec.replicas`, and a Deployment that never became ready. The first two
are visible to a server-side dry run. The third is not visible to any
preview (see Non-goals).

Kix Enterprise reviews plans from `kix diff -o json` (kixpkgs #180, #181).
A review built on the read-only diff tells the reviewer less than the
deploy will find out.

## Proposal

### 1. `kix plan` is the primary preview

`kix plan <cluster>` runs the deploy pipeline as a server-side dry run and
reports, for every object the deploy touches:

- the field changes, old to new, from comparing the object the API server
  says it would produce with the live object (the approach of
  `kubectl diff` and Argo CD's server-side diff);
- what the deploy would refuse or stop on: migration pairs, ownership
  conflicts, admission refusals;
- what it would delete (prune) and what it keeps.

`kix deploy` prints the same plan before it asks for confirmation.
`kix deploy --dry-run` becomes an alias of `kix plan`.

This matches the industry: `terraform plan`, `pulumi preview`, Argo CD's
server-side diff and `flux diff` all answer "what will this change" with
the server in the loop.

A plan needs write permission: a dry run is authorised like the write it
simulates. That is the cost, and it is why `kix diff` stays.

### 2. `kix diff` stays, as the read-only comparison

`kix diff` keeps its name and its job: comparing two things without
writing anything.

- build against the live cluster, read-only (needs `get` and `list` only);
- build against a snapshot (`kix snapshot save`);
- build against another build (`--from <result>`), for example the commit
  that is deployed. This needs no cluster access at all, which makes it the
  safe default for CI that holds no cluster credentials.

Its help text says what it cannot see, and points to `kix plan`.

### 3. One output, enforced by type

Both commands produce the same document, so a consumer (Kix Enterprise, a
CI comment, a script) can take either without knowing which ran.

- One Rust type, `Plan`, in `kix-cli`, serialised by both commands for
  `-o json` and `-o yaml`. The text and Markdown renderers read the same
  value.
- It records how it was made: `made_by` is `dry_run`, `live_read` or
  `builds`.
- Every check a command could not run is typed as not checked, never as an
  empty list, so "no conflicts" and "did not look for conflicts" cannot be
  confused:

```rust
enum Checked<T> {
    Checked(Vec<T>),
    NotChecked,
}

struct Plan {
    made_by: MadeBy,                   // DryRun | LiveRead | Builds
    detail: Detail,                    // Plain | Fields | Manifests (#181)
    packages: PackageDiff,             // today's package and object lists
    migrations: Checked<MigrationPair>,
    conflicts: Checked<OwnershipConflict>,
    admission: Checked<AdmissionRefusal>,
    drift: Checked<DriftChange>,       // see section 4
    prune: Checked<PruneEntry>,
}
```

Enforcement:

- Both commands build a `Plan` and hand it to one renderer; neither has its
  own JSON code path. Today `render_package_diff_json` is already shared;
  this extends it to the whole document.
- A JSON Schema is generated from the type (`schemars`) and committed. A
  test fails when the generated schema and the committed one differ, so a
  shape change is always a reviewed diff, with a version field bumped when
  a change is not backward compatible.
- Tests run both commands against the same fixtures (a kind cluster in the
  integration suite, synthesised graphs in unit tests) and parse each
  output back into `Plan`. A test asserts that where both commands checked
  something, they agree: the `packages` section of a `kix plan` and a
  `kix diff` against the same live state list the same objects.
- `--detail plain|fields|manifests` (#181) applies to both.

### 4. Three-way plans: intended changes and drift

A plan against the live cluster mixes two kinds of change: what the commit
changes, and drift the deploy would undo. The test-cluster plan above
listed a new status page message next to `+ spec.replicas: 1`, which undoes
a `kubectl scale`. A reviewer approving the first should see the second.

A plan compares three things: the deployed build (the Active record's
build, or its reconstruction from live objects as `deploy` does today),
the live cluster, and the new build. Each field change is labelled:

- `intended`: the deployed build and the new build differ here;
- `reverts_drift`: live differs from the deployed build, and the deploy
  puts the deployed value back. Where `kix drift` knows the manager that
  made the change, the plan names it.

A field can be both (the commit changes a field someone also edited by
hand). The text form shows the label; JSON carries it per field change.

`kix diff --from <deployed build>` produces only `intended` changes and
reports `drift: NotChecked`. `kix diff` against live produces both labels
when it can find the deployed build, and a single unlabelled list when it
cannot.

### 5. Reviewed plans should be what ships (goal)

Ideally `kix plan -o json > plan.json` is what a pull request reviews, and
`kix deploy --plan plan.json` refuses when the plan it computes now
differs from the reviewed one (Terraform's saved plans). This is wanted,
but its feasibility is open (see Open questions); v1 of `kix plan` only
reports.

### 6. Where plans run: CI, for now

For now `kix plan` runs wherever its caller has credentials: a person's
kubeconfig, or CI holding a deployer credential. CI that holds no cluster
credentials uses `kix diff --from <deployed build>`, and the plan says it
did not check drift, conflicts or admission.

Running plans inside the cluster (the operator, or a Kix Enterprise agent
that polls for work, the Terraform Cloud agent model) so that callers
never hold cluster credentials is the likely long-term answer. It needs
its own doc: how a build reaches the cluster (binary cache and store
path), who may request a plan, and how results return.

## Motivation

- **One preview that matches the deploy.** The plan comes from the code
  that deploys, with the server answering, so "the plan said fine" and
  "the deploy stopped" stop disagreeing for the reasons a dry run can see.
- **Reviews that separate intent from repair.** Labelling drift reverts
  keeps a pull request's reviewer from approving a hand edit's reversal by
  accident, and tells the operator someone edited the cluster.
- **Interchangeable output.** Kix Enterprise, CI comments and scripts read
  one shape, and know from `made_by` and `NotChecked` exactly how much the
  document can be trusted.

## Relation to existing docs

- **111** defined the plan as the graph diff plus migration pairs, with
  views over it. This keeps that model and makes the server-side dry run
  the source of the field-level part.
- **122** rejects dry runs for continuous drift detection, because a dry
  run costs a write-path round trip per object. That stands: `kix plan` is
  on demand, run once per review or deploy, which is the "diagnosis"
  side 122 reserves the dry run for.
- **81 / 98**: the plan is what the deploy engine executes; `kix plan`
  exposes it without executing.

## Non-goals

- **Readiness.** No preview can say whether a Pod will start, pull its
  image, or pass its probe. `kix plan` says so in its output rather than
  implying the deploy will succeed.
- **In-cluster execution.** Covered by a later doc (section 6).

## Open questions

1. **Saved plans.** What does "the plan changed" compare: the `Plan`
   document minus timestamps, a hash of the field changes, or also the
   live `resourceVersion`s it read? A strict comparison refuses whenever
   anything in the cluster moved (a controller bumping an annotation); a
   loose one lets real drift through. Does a refused deploy offer to show
   the difference?
2. **Webhooks without dry-run support.** A webhook that does not declare
   `sideEffects: None` or `NoneOnDryRun` makes the dry run fail. Is that a
   `kix plan` error, or an `admission` entry that says the object could
   not be checked?
3. **Cost on large clusters.** One dry-run request per changed object, plus
   reads. Should unchanged objects (equal identity hash) skip the dry run,
   as the deploy engine skips them?
4. **Secrets.** The dry-run response carries the Secret values Kix sent.
   The hiding rules from #180 and #181 apply; confirm they cover every
   place a value can reach the output (field changes, manifests, admission
   messages).
5. **Finding the deployed build** for three-way plans when its store path
   is gone and the reconstruction from live objects is itself drifted:
   label as unknown rather than guess?
6. **Naming the not-checked reason.** Should `NotChecked` carry why
   (`no_credentials`, `builds_only`, `webhook_unsupported`) so a reader
   knows how to get the check?
