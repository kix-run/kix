**Status:** Review input to doc 168 (2026-11-13). Doc 168 records the decisions; where they differ, 168 wins.

# Proposal: webhook dry run, SOPS `hash`, and health/drift/status

For 0.10.0. Design only; nothing in the repo was changed. Paths are relative to the repo root. "rc.3" is the code on `main` today.

Summary of recommendations:

1. Webhook dry run: keep the carve-out, because ordering cannot remove the problem. Make it one rule in one place, make its wording true, and stop the 20 second retries.
2. SOPS `hash`: remove it. The library can compute a digest of the encrypted file by itself, and that gives every property the hand-kept value gives today.
3. Health, drift, status: one library function that reads the cluster once and returns three facts for each object. Each command becomes a small renderer.

---

## 1. The webhook dry-run carve-out

### Current behaviour

- Before a deploy writes anything, it sends every write as a dry run and records each answer (`cli/kix/src/cluster/ops/dry_run.rs:68`, `cli/kix/src/cluster/preview.rs:24`). A refused write stops the deploy under the default `--on-error stop` (`cli/kix-cli/src/commands/deploy/mod.rs:146`).
- The answers are sorted into "refused" and "not checked" in the CLI crate, inside the function that builds the plan document (`cli/kix-cli/src/commands/plan.rs:473-612`). "Not checked" already covers three cases where the cluster cannot answer yet: the object's namespace, or its CRD, is created by this deploy, or its CRD is changed by this deploy (`cli/kix/src/plan/document.rs:598-616`).
- rc.3 added a fourth case. When the apiserver says it could not reach a webhook's Service, Kix parses the Service name out of the error text (`preview.rs:277`). If the build contains that Service, the object is "not checked" with reason `webhook_service_written_by_this_deploy` (`plan.rs:508-534`).
- `kix rollback` sorts the same answers with its own code and a different test (`cli/kix-cli/src/commands/rollback.rs:782-830`). It treats namespace and CRD cases as refusals, which `kix plan` does not. This is logged in `housekeeping/2026-11-12-rollback-dry-run-counts-unchecked-as-refused.md`.
- The two commands also disagree about "writes". `plan.rs:514` asks whether the build contains the Service. `rollback.rs:807-815` asks whether the plan will apply it. So `kix plan` can print "which this deploy writes" for a Service that exists, is unchanged, and will not be written. Example: the Service exists but the operator's pods are down ("no endpoints available").
- Each such object costs about 20 seconds. The client retries every HTTP 500 up to 7 times (`cli/kix/src/cluster/client.rs:65`, `:346`), and "service not found" from a webhook call is a 500. Logged on the `housekeeping-rc3` branch (`2026-11-13-dry-run-retries-unreachable-webhook.md`).

### Is ordering the real fix?

No. Ordering helps a little, and it cannot close the gap. Three reasons.

1. Many operators need their webhook configuration to exist before they start. CloudNativePG writes its certificate into the configuration at startup, so the Kix package makes the Deployment wait for the configuration (`kix/packages/stable/cnpg-operator/default.nix:347-349`, `:13-25`). Other operators that write their own certificate into the configuration have the same need (I did not check each package). For these, "Service and pods ready, then register the webhook" is not possible.
2. A deploy that stops partway has, by definition, not finished its order. With any order there is a point where the webhook is registered and its pods are not ready. The incident on 2026-10-17 was an image pull failure, which would leave "no endpoints" even with the Service applied first.
3. The same state arises with no deploy at all: someone deletes the Service, or the operator crashes. The dry run must handle that state anyway.

The real deploy already handles this correctly. Each package makes its custom resources wait for a check Job that proves the webhook answers (`cnpg-operator/default.nix:369-402`). Only the dry run, which runs before any of that, lacks the knowledge.

### Proposed design

The rule in plain words: **a dry-run answer about an object is only final if this deploy does not change what produced the answer.** Kix can tell in four cases: namespace, new CRD, changed CRD, and webhook backend. Keep those four. Do the following.

**A. One classifier, in the library.** Move the sorting out of `plan.rs` into `cli/kix/src/cluster/preview.rs` as one function:

```
classify(answers, plan) -> Vec<(ResourceId, Verdict)>
Verdict = Accepted | Refused(Refusal) | NotChecked { reason, because: ResourceId }
```

`kix plan`, the deploy gate, saved plans, and `kix rollback` all call it. The rollback's private copy goes away. That closes the rollback housekeeping entry.

**B. Make "this deploy writes" true.** A webhook that could not be reached is "not checked" only when the plan will apply (create or change) the Service, or another object of the package instance that owns the Service, such as the operator Deployment. Use the plan's apply set, as rollback does today. Otherwise it is a refusal with its own advice: the webhook's backend is down, this deploy does not repair it, and `kix deploy --reconcile` recreates a deleted Service. Today that case passes the gate with a false sentence and then nothing writes the Service (`housekeeping/2026-11-12-deploy-does-not-recreate-deleted-objects.md`).

**C. Name the cause as data.** Add `because` (the Service, CRD, or Namespace) to each "not checked" entry of the plan document, beside the prose `detail`. Adding a field is not breaking.

**D. Settle the reason name before 0.10.0.** The reason `webhook_service_written_by_this_deploy` has only shipped in rc.3. If B is accepted, rename it now to `webhook_backend_written_by_this_deploy`. After 0.10.0 a rename is a breaking JSON change.

**E. Do not retry a dry-run 500.** A dry run is a question, and a 500 from a webhook call does not change in 20 seconds. In `client.rs`, treat a request with `dryRun=All` in its query the way watches are already recognised (`client.rs:299`): keep retries for 429 and 503, drop them for 500. Real applies keep their retries, which help while a webhook pod starts.

**F. Leave ordering to packages, and write the convention down.** Where an operator does not need its configuration at startup, the package should make the configuration wait for the workload. Where it does, the package gates custom resources on a check Job, as cnpg does. Put this in the `package-authoring` and `package-review` skills. No engine change.

### Alternatives rejected

- **Engine applies webhook configurations last, by kind** (what Helm and kustomize do). Breaks operators that need the configuration first, and adds a second ordering rule beside the dependency graph.
- **Work out before the dry run which objects a broken webhook would catch.** Kix would have to copy the apiserver's matching rules (namespace selectors, object selectors, CEL conditions). Too much to get right.
- **Treat every webhook error as "not checked".** A webhook that answers "no" is the most useful thing the dry run finds.
- **Skip the dry run for objects whose dependencies change.** Loses checks that work today, such as schema validation.

### Not in this proposal, worth a later look

- A webhook that answers "denied" because it is the old operator version, where this deploy upgrades the operator (`housekeeping/2026-10-18-preview-fails-on-old-operator-webhook.md`). Rule B could cover it, but it would also hide real denials during every operator upgrade. See open question 1.
- An engine-level wait: when a real apply fails because a webhook is unreachable and its Service belongs to this deploy, wait and retry inside the object's timeout. That would replace the check-Job wrapper each operator package copies (`housekeeping/2026-10-02-crd-handle-gate-copied-per-package.md`).

### Breaking and cluster-state impact

None for cluster state. No CLI flag changes. Plan JSON: one reason renamed (rc.3 only, so no breaking record; amend the unreleased record) and one field added. Behaviour: case B turns one "not checked" into a refusal compared with rc.3. Rollback becomes more permissive in the namespace and CRD cases, which is a fix.

### Effort

Medium. A and B are a refactor with tests that already exist to move. C, D, and E are small. F is text.

### Open questions for the owner

1. An add-on is being upgraded, and its old version rejects one of your objects during the pre-flight check. The new version might accept it. Should Kix (a) stop and tell you, as today, or (b) go ahead and let the real deploy find out, which may fail halfway? I recommend (a) for 0.10 with a clearer message.
2. If a safety check on the cluster is broken and your deploy does nothing to repair it, should the deploy stop before it starts (my proposal), or start and fail at the first affected object (rc.3)?
3. Is the name of the "not checked" reason in the JSON plan worth one more change before 0.10.0, given it cannot change freely afterwards?

---

## 2. The SOPS `hash`

### Current behaviour

- `scope.mkSecret` takes `source` (the encrypted file) and an optional `hash` (`kix/lib/scope/builders.nix:842-843`). The `secret` package passes both through (`kix/packages/stable/secret/default.nix:35-44`).
- `hash` is the SHA-256 of the **decrypted** values, as sorted `key=value` lines (`cli/kix/src/cluster/secrets.rs:661-672`). The library writes it to the annotation `kix.run/content-hash` (`builders.nix:947-949`).
- At deploy, Kix decrypts the file, computes the same digest, and stops on a mismatch (`secrets.rs:546-556`). For a bundle the annotation is required (`secrets.rs:200-202`, `:225`).
- rc.3 added `kix secret hash <file>`, a `hash_mismatch` plan reason, a `sops_source` field, and advice that guesses which instance to edit (`cli/kix-cli/src/plan/render.rs:251-257`).

### Why it exists, and why it is no longer needed

The first design (`discussions/archive/76_secrets_design.md:51-55`) copied the "download with a checksum" pattern. In that design the build never saw the encrypted file. The hash in the definition was the only thing that made a changed secret change the build, and so restart the pods that read it.

That is no longer true. The library now copies the encrypted file into the build (`builders.nix:920-927`) and writes its content-addressed path to `kix.run/sops-source` (`builders.nix:945`). So:

- **A changed file already changes the build.** The path changes, so the Secret's manifest and identity hash change, and every pod with a `checksum/<name>` annotation for that Secret restarts. `hash` adds nothing.
- **The check cannot catch tampering.** SOPS files are encrypted to public keys. Anyone who can change the file in git can encrypt values they chose, and can compute the matching hash for them. SOPS's own integrity code already catches a damaged file.
- **The check mostly catches forgetting to update the hash.** It is a second entry of the same fact, and every stale value is a stopped deploy. Five housekeeping entries are about this value (2026-10-17, three on 2026-11-11, one on 2026-11-12).
- **It publishes a digest of secret values.** Kix refuses to print the computed hash and hides it in plans, because it is derived from plaintext (`secrets.rs:65-68`). Yet the user must commit that same digest to git. For a weak password it allows offline guessing by anyone who can read the repo.

Two things do use the value. The database packages name their bootstrap Job after it, so a new password reruns the Job (`kix/packages/experimental/stackgres-database/default.nix:289-296`, `clickhouse-database/default.nix:352`). Bundles use it to check that the file they carry is the one the build meant. Both work as well with a digest of the encrypted file.

### Proposed design

1. **The library computes a digest of the encrypted file.** In `mkSecret`: `digest = builtins.hashFile "sha256" source`. It needs no key and no user input. Write it to a new annotation, `kix.run/sops-digest`.
2. **The deploy checks the file's bytes before decrypting.** It hashes the file it is about to decrypt and compares. In a local deploy this can only fail if the store is damaged. For a bundle it is a stronger check than today, because it runs before any decryption.
3. **Remove `hash`** from `scope.mkSecret` and from the `secret` package. Setting it fails the build with a numbered error that says to delete the line. The published value `out.sops` becomes `{ source; digest; }` (`builders.nix:980`, `kix/contracts/stable/secret.nix:55-59`). Reading `out.sops.hash` fails with the same numbered error.
4. **Database packages** use `sops.digest` for the Job name.
5. **Remove the rc.3 additions that only served the hand-kept value:** `kix secret hash`, the `hash_mismatch` reason, `sops_source`, `stops_only_on_hash_mismatch` (`cli/kix/src/plan/document.rs:699`), and the instance guess. None has been in a stable release.
6. **Old builds:** a rollback target or bundle built by 0.9 has `kix.run/content-hash` and no digest. The deploy ignores the old annotation and skips the digest check when there is none. For a bundle without a digest, keep today's decrypted-value check for six months, then delete it.
7. The annotation `kix.run/content-hash` is retired. That also ends its double use (`housekeeping/2026-10-17-secret-hash-unverified-and-shares-content-hash-key.md`).

Net effect on code: more removed than added. The docs lose a section (`docs/src/content/docs/how-to/platform-capabilities/use-sops-backed-secrets-if-production-ready.mdx:75-103`, `reference/secrets-crds-and-rbac.mdx:41`).

### Alternatives rejected

- **Keep `hash`, keep `kix secret hash`.** Leaves the double entry, the stopped deploys, and the committed digest of plaintext.
- **Keep `hash` optional.** Two ways to do one thing, and the database packages would need both paths.
- **Kix writes the hash into the `.nix` file for the user.** Kix does not edit user source anywhere else, and the value would still be redundant.
- **Use the Secret's identity hash for the bootstrap Job name.** That hash moves when unrelated dependencies change (`housekeeping/2026-11-06-identity-hash-cascade-restarts-pods.md`), so Jobs would rerun for no reason.
- **Rely on the store path alone, no new annotation.** Works locally. A bundle cannot cheaply check a carried file against a store path.

### What is given up

Re-encrypting a file without changing its values (for example, adding a team member's key) changes the digest. Pods restart and the bootstrap Job reruns with the same password. This already happens today, because the file's path is in the manifest. The decrypted-value hash never prevented it.

### Breaking and cluster-state impact

- `error` record: `hash` on `scope.mkSecret` or a `secret` instance fails the build and names the fix. Library and package change, minor release.
- `error` record: the `secret` contract's `sops` shape changes. This affects packages outside this repo that read `out.sops.hash`.
- `note` record: on the first deploy after upgrading, every SOPS Secret changes by one annotation. Pods that read one restart once. Each database bootstrap Job runs once more under a new name.
- Cluster state: the live annotation `kix.run/content-hash` is removed from Secrets by that deploy. Nothing in Kix reads it from the cluster (`cli/kix/src/plan/redact.rs:211` only hides it), so no required stop and no state fixture.
- CLI: `kix secret hash` is removed before it reaches a stable release. The unreleased records `changes/secret-hash-command.md` and `changes/sops-hash-mismatch-message.md` are deleted or rewritten.

### Items of the secrets to-do list this touches

- **2** (`helpers.use` with checksum and reloader wiring): the `sops` field of the secret contract changes shape. Do this first so `helpers.use` is written once.
- **6** (generated secrets, parked): becomes simpler, since a generated file needs no hash step.
- **8** (an rc is needed to test secrets as a release): this adds to that rc.
- **10** (Lithus private packages are unchecked): any that pass `hash` or read `out.sops.hash` will fail to build until edited.
- **11** (the committed test key in `clusters/dev-secrets/`): the hashes beside it go away. The key question stays open.
- **12** (non-SOPS database path): not changed. That path has no fingerprint today, so a changed password does not rerun the bootstrap Job. Worth a housekeeping entry.
- **13** (Lithus builds were byte-identical): no longer true after this.
- Not touched: 1, 3, 4, 5, 7, 9.

It does not fix `housekeeping/2026-10-03-sops-secret-out-of-band-change-invisible.md` (a secret edited on the cluster by hand is invisible). The old hash did not fix that either.

### Effort

Small to medium. Mostly deletion, plus one annotation, one check, tests, docs, and three database packages.

### Open questions for the owner

1. Today you write a checksum next to each encrypted secrets file, and the deploy stops when the two disagree. Did you want that as a deliberate second confirmation that a secret changed? If so, Kix can show "these secret files changed" in the plan instead, with nothing to maintain.
2. After upgrading, every app that reads an encrypted secret restarts once. Is that acceptable for both current users, with a line in the upgrade notes?
3. rc.3 added a command that prints the checksum. It would be removed again before the final release. Any objection?

---

## 3. `kix health`, `kix drift`, `kix status`

### What each computes today

| | `kix health` | `kix drift` | `kix status` |
|---|---|---|---|
| Code | `cli/kix-cli/src/commands/health.rs` (772 lines, all in the CLI crate) | `cli/kix/src/cluster/drift.rs` (732) and `cli/kix-cli/src/commands/drift.rs` (346) | `cli/kix-cli/src/commands/status.rs` (925) |
| Question | Does every object of the current build exist? | Is every object still as Kix applied it? Since rc.3, also: does it exist? | Is every object ready? With `--operator`, also: does it exist? |
| Reads from the cluster | Current deploy record, all Kix objects (`health.rs:110-131`) | All current records, all Kix objects (`drift.rs:132-176`) | Current record, all Kix objects (`status.rs:236-281`, `:532-549`) |
| How it decides "missing" | Follows `kix.run/depends-on` annotations from the record; a dependency with no live object is missing (`health.rs:274-366`) | Record's package index minus live identity hashes (`drift.rs:185-242`) | Local copy of the build minus live objects by name, shown as `NotFound` (`status.rs:380-420`) |
| How it names a missing object | Local store, else a hash prefix (`health.rs:221`, `:623`) | Local store, else `Unknown (hash: ...)` (`drift.rs:171`, `:222-229`) | Only works when the build is on this machine |
| Groups by package using | Annotations on live objects (`health.rs:394`) | Not grouped | Local copy of the build (`status.rs:267-273`) |
| Other verdicts | "At risk": depends on something missing | In sync, drifted (with who changed which field), not stamped | Ready flag and a status text per kind (`status.rs:674`) |
| Needs a build or evaluation | No | No | Plain `kix status` evaluates the cluster only to learn its name (`status.rs:221`) |

### Duplication and gaps

1. **Three ways to find a missing object**, which can disagree. The two added in rc.3 (health's filter for non-object dependencies, `health.rs:245-272`, and drift's `missing_objects`) solve the same problem twice.
2. **Three ways to connect and sweep.** Health uses a call that drops the list of kinds the account may not read (`health.rs:124`, `cli/kix/src/cluster/inventory.rs:245-254`). Drift does not look at that list either. So an object of a kind the account cannot list looks missing in both. Only status prints the note (`status.rs:286`).
3. **Three ways to turn a live object into a name**: `health.rs:142`, `drift.rs:546`, `status.rs:461`.
4. **Two ways to group by package**, neither using the package index that every deploy record already carries (`cli/kix-core/src/eval/package_index.rs:37`).
5. **Names depend on the machine.** The record's index holds only hashes. On a machine without the build, a missing object has no name.
6. **Health's logic lives in the CLI crate**, so nothing else can call it. Status's per-kind status text (`status.rs:674-750`) sits beside the library's readiness rules (`cli/kix/src/cluster/readiness/`) and repeats part of them.

### Proposed shared core

One library module, `cli/kix/src/cluster/observe.rs`, with one entry point:

```
observe(client, discovery, records, scope) -> ClusterView

ClusterView {
  record:    Option<Record>          // the current deploy record
  objects:   Vec<ObjectView>         // every expected or live object, once
  packages:  package -> object ids   // from the record's index
  unreadable_kinds, notes            // partial views are always reported
}

ObjectView {
  rid, identity_hash, package,
  presence:  Present | Missing | Unknown(kind not readable) | External
  content:   InSync | Drifted{..} | Unstamped | NoFieldset   // today's check_object
  readiness: Ready | NotReady(text) | NotApplicable
  depends_on: Vec<hash>
}
```

How it is built:

- One sweep (`inventory::sweep_managed`) and one read of the records, in the order drift uses today (records first, `drift.rs:142-152`).
- **Expected set**: the record's package index. It is the only source that works on every machine. A record without an index (written before indexes existed) falls back to health's walk of `depends-on`.
- **Presence**: join expected and live by identity hash, then by name, so an older version of an object left by a failed deploy is not "missing" (drift's rule, `drift.rs:219-221`). A kind the account cannot list gives `Unknown`.
- **Content**: `drift::check_object`, unchanged.
- **Readiness**: the library's readiness rules, with status's text moved in beside them.
- "At risk" is a small pure function over the view: anything that depends, directly or not, on a `Missing` object.

Each command is then a projection and a renderer, about 100 to 150 lines:

- health: `presence` and "at risk".
- drift: `content` and `presence`.
- status: `readiness`, grouped by `packages`.

**If the commands are merged**, the one command prints all three columns from the same `ClusterView`. **If they stay separate**, each prints its own column. The core, the exit-code helpers, and the JSON shape of an object are the same either way. I suggest the JSON for one object carries all three facts in every command, so scripts do not care which command produced it.

**Optional second step: put names in the record.** Add a field beside the package index that maps each identity hash to `Kind/namespace/name`. Then a missing object has a name on every machine, and the local-store lookup (`store_graph::lookup_hashes`, and `housekeeping/2026-11-07-health-scans-whole-store-per-hash.md`) is only needed for old records. Cost: about double the index, which is 9 KB for 223 objects today against a 150 KB limit (`package_index.rs:28-32`).

### Alternatives rejected

- **Leave three implementations and share small helpers.** The three definitions of "missing" would keep drifting apart, as rc.3 shows.
- **Make health the core and have the others call it.** Its dependency walk needs annotations on live objects, so it cannot see an object whose only parent is also gone. The index can.
- **Compute everything from a fresh build.** Drift and health are valuable because they need only cluster access. `kix diff` already covers the build-versus-cluster question.

### Breaking and cluster-state impact

- The core alone: none. Output can stay as it is, command by command. Two visible fixes: unreadable kinds are reported and no longer shown as missing, and health names objects it could not name before. Both are `fixed` records.
- Plain `kix status` would stop evaluating the cluster to learn its name. That is faster and changes no output.
- The optional names field is new cluster state, added beside the existing index so that older Kix versions keep reading the index they know. Kix 0.10 keeps reading records that lack it. It needs a change record with `state = true` and a fixture folder. No required stop.
- Any change to command names, flags, or exit codes belongs to the other agent's proposal.

### Effort

Medium for the core and the three renderers. Most tests move with the code. Small for the names field.

### Open questions for the owner

1. When a check runs with an account that cannot see some kinds of object, should it (a) pass with a warning that the view is partial, or (b) fail? I recommend (a) with exit code 0 only if everything visible is fine, and a clear line naming what was not read.
2. "At risk" today means "this object exists, but something it depends on is missing". Is that a status you use? If not, it can be dropped and health becomes a plain list of missing objects.
3. May the deploy record grow by a list of object names (about 10 KB for a 200-object cluster), so that these commands can name a missing object from any machine?
4. Should the three checks appear in one JSON shape, even if the commands stay separate? It makes scripts simpler and costs a few unused fields.
