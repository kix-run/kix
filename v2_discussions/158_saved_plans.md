# 158: Saved plans, `kix deploy --plan`

**Status:** Design (first draft, rules agreed in kixpkgs#185)
**Related:** `archive/157_kix_plan_primary_preview.md` (§5, the goal), kixpkgs#185 (the rules), kixpkgs#186 (the document fields this relies on)

## Context

Kix Enterprise reviews a `Plan` document (`kix plan -o json`, or `kix diff
-o json` on clusters too large to dry-run on every review) and approves it.
The deploy that follows should apply what was approved. Doc 157 §5 named
the goal: `kix deploy --plan plan.json` refuses when the plan it computes
now differs from the reviewed one. It left open what "differs" means.

kixpkgs#185 settled that. This doc says how the deploy implements it.

Two facts shape the design:

- **`kix deploy` builds from source.** It never applies a stored plan. It
  rebuilds, plans again, and compares. A saved plan restricts a deploy; it
  never supplies its content. A tampered `plan.json` can at worst make the
  deploy refuse.
- **The document is lossy on purpose.** Secret values read `(secret, not
  shown)` and values over 16 KiB read `(N bytes, not shown)`. Two plans
  can print the same field change for different values, so the comparison
  cannot rest on the values the document shows.

kixpkgs#186 added the fields the comparison keys on: `build` and
`deployed` (each with an `identity_hash`), `flags`, and `kix`.

## Design

### The command

```
kix deploy <cluster> --plan plan.json [--yes] [planning flags]
kix deploy <cluster> --plan plan.json --dry-run
```

1. Read `plan.json` into `plan::document::Plan`. Refuse a `schema_version`
   this Kix does not know, and a document that does not parse.
2. Take the planning flags from the saved plan's `flags`. A planning flag
   given on the command line that contradicts it is an error before any
   build: `--prune` against a plan made without it, or the reverse.
   Repeating a flag the plan already has is allowed.
3. `deploy::prepare` with those flags, then the dry-run pass and
   `plan::document`, as every `kix deploy` does today.
4. `plan::saved::compare(&reviewed, &fresh)` returns the mismatches. Any
   mismatch refuses the deploy, before the stop check and the
   confirmation, and nothing is applied.
5. Otherwise the deploy continues unchanged: the refusal stop under
   `--on-error stop`, the confirmation unless `--yes`, the apply.

With `--dry-run`, steps 1 to 4 run and the command exits after printing
the result. CI can check a reviewed plan is still current without
deploying.

`--plan` and `--current-activation` together are refused: an offline plan
cannot see the cluster's current record, so rule 2 below could not hold.

### What "differs" means

Each rule compares the reviewed plan (R) with the fresh one (F). A rule
that cannot be checked because R did not check it (a `kix diff` plan) is
skipped and named in the output, never passed silently.

| # | Rule | Compared on | Why |
|---|------|-------------|-----|
| 1 | Same Kix | `kix.store_path` when both have one, else `kix.version` | A newer Kix can compute a different plan from the same builds. Kix Enterprise runs plan and deploy from one commit, so this costs it nothing |
| 2 | Same cluster | `cluster` | A plan for one Kix cluster cannot approve another |
| 3 | Same new build | `build.identity_hash` | The reviewer approved these manifests. The store path only finds the build; a rebuild on another machine can land at another path with the same manifests |
| 4 | Same deployed build | `deployed.identity_hash`, both `null` on a first deploy | The intended changes are exactly the difference between the deployed and the new build, so rules 3 and 4 together pin them, without comparing lossy values. A deploy that landed between review and apply fails this rule, and the message names both records |
| 5 | Same flags | `flags` | `--prune`, `--reconcile`, `--force-conflicts` and `--accept-migrations` each change what the deploy writes or deletes |
| 6 | No new refusal | conflicts by resource; admission refusals by resource and `reason` | Messages are left out of the key, since apiserver wording varies between versions and webhook runs |
| 7 | No new reverted drift | `drift` items with `reverted: true`, by resource and path | Otherwise the deploy undoes a hand edit nobody reviewed. The live value is left out of the key, so a controller rewriting a field it already drifted does not refuse the deploy |
| 8 | No new prune delete | `prune` items with fate `delete`, by resource | Deletes are the most destructive write, and they can change without either build changing: an orphan shared with another Kix cluster becomes deletable when that cluster stops claiming it |

Everything else is ignored: `resourceVersion`s, timestamps, `drift_kept`,
fields other managers own that the deploy does not touch, objects that
moved between `not_checked` and checked, and the order of any list.
Migrations need no rule of their own: they are computed from the deployed
and new manifests, which rules 3 and 4 pin.

Rules 6 to 8 only refuse on what is new in F. Something in R that is gone
from F (a conflict someone resolved, drift someone reverted) does not
refuse: the deploy now does less than was approved, never more.

### Saved `kix diff` plans

A plan with `made_by: live_read` can be saved too. Kix Enterprise falls
back to it on clusters where a dry run of every review is too expensive.

- Rules 1 to 4 and 7 apply. The deployed record comes from the live
  Activation record in both plans.
- Rules 6 and 8 are skipped: a diff does not check conflicts, admission,
  or prune. The output says so. The deploy still runs its own dry run
  first, so a refusal still stops it under `--on-error stop`; the dry run
  was just not part of what was reviewed.
- Rule 5: a diff plans no deploy, so its `flags` is `null`. A deploy from a
  diff plan refuses `--prune`, `--force-conflicts`, and `--reconcile`,
  since no reviewer saw what they would do. `--accept-migrations` is
  allowed, because the diff lists migrations.
- Plans with `made_by: builds` (`kix plan --current-activation`, `kix diff
  --from <build>`) are refused: no cluster was read, so rule 4 and rule 7
  have nothing to stand on.

### Output

A refusal lists each failed rule with the items that differ, and exits
`4`, a code no other Kix command uses, so CI can tell "the reviewed plan
is stale" from an error (`1`) or a stopped deploy:

```
The reviewed plan no longer matches (plan.json):
  [deployed build] the cluster now runs prod-9f3c (identity 9f3c…),
                   the plan was made against prod-1a2b (identity 1a2b…)
  [new drift]      Deployment/api@app $.spec.replicas: changed by kubectl-scale
Not compared, the reviewed plan is a kix diff: conflicts, admission, prune.
Review a new plan, or deploy without --plan.
```

`-o json` prints `{ "matches": bool, "mismatches": [ { "rule", "items" } ],
"skipped": [rule] }` for Kix Enterprise to show beside the review.

### Code

- `cli/kix-cli/src/plan/saved.rs`: `Mismatch`, `Rule`, and `compare(R, F)
  -> Comparison { mismatches, skipped }`. Pure, so every rule is a unit test
  over two `Plan` values.
- `cli/kix-cli/src/cli.rs`: `--plan <FILE>` on `DeployArgs`, the flag
  conflict check, and `--plan` with `--current-activation` refused.
- `cli/kix-cli/src/commands/deploy.rs`: load, merge flags into `PlanArgs`
  before `prepare`, call `compare` after `plan::document`. When the deploy
  skips the dry run (nothing to apply or prune), F's write-path sections
  read as checked and empty today; for `--plan` they must read
  `not_checked` so rules 6 and 8 are skipped honestly
  (housekeeping `deploy-plan-without-dry-run-says-checked`).
- The kind integration test: plan, save, deploy with `--plan` (matches);
  plan, `kubectl scale`, deploy with `--plan` (exits 4 on rule 7); plan,
  deploy, deploy the old plan again (exits 4 on rule 4).

## Alternatives considered

- **Compare the document minus noise, or a hash of the field changes.**
  Rejected in #185. Hidden and truncated values make it pass when values
  differ, and server-normalised values make it refuse when nothing
  differs.
- **Compare the `intended` field changes** (#185's first rule 2).
  Replaced by rule 4: same builds on both sides imply the same intended
  changes, and a deploy landing in between is named directly instead of
  showing as a list of changed fields.
- **Apply the stored plan, Terraform style.** Kix has no plan artifact to
  execute: it rebuilds. Deploying the reviewed store path fetched from a
  binary cache is the nearest equivalent, and waits for the in-cluster
  doc (below).
- **Store full manifests in the plan to compare.** Rejected: a plan is
  meant to be shared, and built manifests carry Secret values inline
  (the same reason doc 138 keeps manifests out of the Activation record).

## Not in this doc

Both wait for the in-cluster plan and deploy doc (157 §6):

- **A `resourceVersion` precondition** on each apply that reverts drift,
  so a hand edit between the fresh plan and the apply is rejected by the
  apiserver (409) instead of reverted. Rules 6 to 8 hold at plan time
  only until then.
- **Deploying from a binary cache**: `kix deploy --plan` realising
  `build.store_path` instead of rebuilding, which makes rule 3 hold by
  construction.

## Open questions

1. **A Kix binary outside the Nix store** (`kix.store_path: null`, a
   `cargo build`): rule 1 falls back to `kix.version`, which does not move
   with every commit. Good enough for development, or refuse `--plan`
   unless both plans name a store path?
2. **Conflict identity**: rule 6 keys a conflict on its resource. A new
   field in conflict on an object that already had one does not refuse.
   Key on resource and field paths instead? The paths are in `owners`.
3. **Exit code `4`** versus reusing `3` ("the deploy would stop"). `4`
   keeps "stale review" apart from "the cluster would refuse", which are
   different calls for a person to make.
