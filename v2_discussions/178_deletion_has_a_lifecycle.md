# 178: Deletion has a lifecycle: prune waits until objects are gone

**Status:** Draft (design doc). Written 2026-11-24 from code, three kind test logs, and five housekeeping entries. Nothing here is built.
**Related:** `81_deploy_as_lifecycle_engine.md` (Delete as a transition), `98_deploy_execution_topology.md`, open PR #317 (`175_one_home_for_what_a_deploy_did.md`, `176_housekeeping_design_read.md` theme 3 and 4), `ROADMAP.md` ("Prune waits for custom-resource finalizers", "Interleaved prune waves")
**Housekeeping it would close:** `2026-10-02-prune-does-not-wait-for-crd-finalizers.md`, `2026-10-02-readiness-counts-terminating-objects-ready.md`, and on the keda and db-operator branches `2026-11-24-prune-log-says-deleted-objects-still-there.md`, `2026-11-24-no-convention-orders-crs-before-operator-prune.md`, `2026-11-24-deploy-log-says-pruned-objects-remain.md`. It also answers half of `2026-11-23-operator-teardown-drops-finalizer-after-failed-deletes.md`.

All output text below is a sketch for the design. The copy pass writes the real wording later.

## 1. What happened

Three live tests on kind (2026-11-24) removed an operator and its custom resources in one `kix deploy --prune`.

| Test | What stuck | What Kix said |
|---|---|---|
| KEDA, operator scaled to 0 before the deploy | ScaledObject `app/worker` Terminating with `finalizer.keda.sh`. Its HPA stayed, and the workload froze at 3 replicas. | `0 failed, 43 pruned`. `kix status`: `80 resources: 80 ok`. Only `kix gc --full-scan` listed the object, with no word that it was being deleted. |
| KEDA, operator healthy (twice) | Nothing. The operator cleared the finalizer 13 ms after the delete, 3 s before its own pod got a deletion timestamp. | Success, correctly, by a race the user usually wins. |
| DB Operator, controller at 0 during the deploy | Database `apps/app-db` Terminating with `db.app-db`. When the controller came back it needed the DbInstance, which Kix had already deleted. | `12 pruned`. `kix status` silent. After a manual reproduction, `kix deploy --reconcile` reported the Terminating Database `configured` and `ready`. |
| DB Operator, namespace filter narrowed in the same deploy that removed Databases from the excluded namespace | Databases Terminating forever: the controller checks the filter before it handles deletion. | `pruned`, `222 ok`. |

The line log also printed `<object>> left the build, still on the cluster` for each object it deleted, then `<object>> ready`.

Recovery in every case was to put the operator (or the DbInstance, or the wider filter) back, deploy, wait for the finalizer, then remove it again with `--prune`. Earlier, mayastor DiskPools and arc runner sets hit the same thing, and their how-tos tell users to remove the custom resources first and wait.

## 2. Zoom out: one missing concept

Apply is an operation with a lifecycle: Kix sends the write, then waits for readiness, with a budget, terminal-failure detection, progress events, and a verdict. Delete has no lifecycle. Kix sends the request and counts the object as pruned. Kubernetes deletion is itself a process: the request sets `metadata.deletionTimestamp`, every finalizer must be removed by whoever owns it, and only then does the object go. "Requested" and "gone" are different states, and Kix knows only the first.

The missing concept is **deletion as an operation with states**: *requested*, *finalizing* (deletion timestamp set, finalizers listed), *gone*, and *stuck* (finalizing past the budget). Apply's readiness has the same shape. Most of the symptoms fall out of the gap:

| Symptom | Cause |
|---|---|
| Custom resource stuck after its operator was deleted in the same run | The gap. Nothing waits for the resource to be gone before deleting what it needs. |
| `0 failed, 43 pruned` while an object remains | The gap. `Pruned::Deleted` means "the API accepted the request" (`prune_guard.rs`). |
| The line log prints `ready` for each deleted object | The gap. The scheduler emits `Verdict::Ready` for a delete the moment the request returns (`scheduler/mod.rs` prune). |
| The next `deploy --prune` and soft `kix gc` forget the stuck object | The gap. A delete that "succeeded" leaves `orphans_left` false, so the new record drops the build it came from from `status.orphansKeptFrom`. Only `gc --full-scan` finds it again. |
| `kix status` says `ok` for a Terminating object in the build, and `deploy --reconcile` says `configured, ready` | The gap, on the apply side. Readiness, drift, and status never read `deletionTimestamp`. |
| `kix status` never mentions a stuck object that left the build | The gap. Status reads only the objects of the current build. |
| `kix gc --full-scan` lists the object without saying it is being deleted | The gap. |
| The operator removes its Activation finalizer although objects remain | The gap, in the operator's teardown path (`delete_in_order`). |
| Each deleted object is printed as "left the build, still on the cluster" | A separate bug. `prune_lines` has one per-object text for "will delete" and "will keep". |
| Nothing orders a custom resource before the operator that serves it | A separate gap. A resource built with `scope.mkCRD` depends on its CRD, and on the operator only when the package remembers `crRequires`. 15 of the 19 package files that call `scope.mkCRD` set none (chart packages get the chart's workloads through `extraRequires`). |
| Narrowing the namespace filter strands Databases | A separate problem. The config change is applied before prune runs, so no delete order fixes it. Waiting makes it loud. Interleaving deletes with applies (ROADMAP "Interleaved prune waves") is the real fix and is out of scope. |

So there are two pieces of design work: a deletion lifecycle (one gap, eight symptoms) and an ordering declaration (one gap). Waiting without ordering makes the failure loud but still strands the resource. Ordering without waiting only wins the race more often.

One owner is missing too. Kix already waits for a delete in one place: `recreate_in_place` (`ops/resources.rs`) polls by name for 30 seconds before it applies again. Doc 176 plans a second (replace waits until the object is gone). This design gives the decision "is this deletion done" one function that recreate, replace, prune, gc, and the operator all call.

## 3. What Kix knows today

- **Prune** runs after every apply node is done (`Run::prune`). It deletes orphans one at a time in reverse dependency order, each call under a 60-second limit, with `propagationPolicy: Background`. It does not wait.
- **Order** comes from `prune_order` (`scheduler/node.rs`): a graph over the orphans' old manifests, with edges only between orphans. On a cycle it falls back to name order.
- **`kix gc`** and the operator's teardown delete through `delete_in_order` with `DeleteParams::default()`, so they use each kind's default propagation while deploy uses `Background`.
- **Never deleted:** Namespaces and CRDs (`never_pruned`, `kix-core/src/manifest/lifecycle.rs`). Confirmed for deploy, rollback, every gc mode, and operator teardown.
- **The prune guard** reads each object before deleting it, then deletes with its uid and resourceVersion as preconditions. So Kix already holds the live object, including `metadata.finalizers` and `deletionTimestamp`, at the moment of the delete.
- **The plan** sends each prune delete as a server-side dry run and records a fate (`delete`, `delete_refused`, `kept_*`). It reads the live objects.
- **Edges a custom resource has:** its CRD, `crRequires` (often a webhook check Job that itself requires the operator), and for chart operators the chart's workloads (`extraRequires`). KEDA and db-operator, on their branches, set `crRequires`.

## 4. Designs

### A. Wait for each deleted object to be gone, in the existing prune loop

After each delete, poll the object by uid until it is gone (404, or another uid) or the budget runs out. The budget is `--timeout` (default 180 s) of no progress, where progress is the finalizer list getting shorter, under the same hard ceiling as readiness. An object that does not go is a failed delete: the deploy names its finalizers, and Kix does not delete the orphans it depends on (they stay recorded as orphans for the next prune). An object already being deleted when prune reaches it is not deleted again, only waited for.

- **Fixes:** the false success, the forgotten orphan, operator deleted under a dependent that is still finalizing (when the edge exists).
- **Does not fix:** a custom resource with no edge to its operator. Order between the two is name order, so the operator may still go first. The deploy then fails loudly after the budget.
- **Cost:** one extra read per deleted object in the common case (no finalizer, gone at once). The loop stays serial, so a slow delete holds every later one. A real finalizer costs what the operator takes, usually under a second.
- **Size:** S. It touches `Run::prune`, `PruneGuard`, and the line log.

### B. A, plus a plan-time check

The plan already reads each orphan. It also lists its finalizers, and when the object's kind declares a controller (design C) that is not ready, it warns. Without C, Kix could only refuse on a guess (a finalizer's domain resembling a CRD group), which CLAUDE.md "Fixing bugs" rules out. Refusing (exit 3) is not needed once deletes wait, because waiting keeps the operator alive. A warning is enough.

- **Adds:** the user learns before the deploy that a delete will wait, and on what.
- **Cost:** no extra requests; the plan reads these objects already. Small. Worth little without C.

### C. A library declaration of which workload handles a custom resource kind

`scope.mkCRD` and `scope.mkCRDRef` take `controller`: the workload (or workloads) that reconciles resources of the kind, or `null` for a package that ships only the type (gateway-api). The library adds it to every custom resource's dependencies, as `crRequires` does today, so apply waits for the operator to be ready before creating resources, and prune deletes them before the operator. Because consumers build resources from the operator package's `out.crds`, the edge crosses packages without anyone remembering it.

- **Fixes:** the ordering gap, for every operator, once.
- **Cost:** 15 native packages gain one line. An unwanted cycle is possible when an operator's own workload depends on a resource of a kind it serves; the build refuses it and names the cycle. None is known in the package set.
- **Alone it is not enough:** with the operator scaled to 0, order is right and the resource still sticks, silently, as in the KEDA test.

### D. (Recommended) Deletes are scheduler nodes with a "gone" verdict, plus C, plus B's plan column

Implement A's lifecycle in the engine instead of the post-loop. Each orphan the prune deletes becomes a `Delete` node of the plan DAG (the stream already has `TransitionKind::Delete`). Delete nodes run after every apply node, as now, with the orphan edges reversed: a node may be deleted once every orphan that depends on it is gone. The node's verdict comes from `wait_gone`, the one function that owns "is this deletion done", which recreate and the doc 176 replace also call.

This reuses what apply nodes have: bounded concurrency, the watchdog's `waiting>` lines, cancellation, `--on-error stop|continue` with cancelled dependents, and the JSON node events. It is also the first step of the "Interleaved prune waves" roadmap item, since a delete node can later get edges into the apply part of the DAG.

- **Cost against A:** M instead of S. Faster in the common case, because independent deletes run concurrently where today they run one by one.
- **Readiness rule (section 7):** an object being deleted is not ready, and an apply onto it waits for it to go, then creates it.

## 5. What the user sees under D

**`kix plan keda --prune`** (draft). The prune section gains what each delete will wait for:

```
Prune (--prune): 43 objects to delete
  - ScaledObject.keda.sh app/worker    waits for finalizer.keda.sh; deleted before Deployment keda/keda-operator
  - Deployment keda/keda-operator      deleted after 6 objects that need it are gone
  ...
! Deployment keda/keda-operator has 0 of 1 pods ready. It handles ScaledObject app/worker,
  so that delete will wait for it, and the deploy fails if it is not back within 3m.
```

Exit codes unchanged: 2 when something would be deleted, 3 only for a refused delete.

**`kix deploy keda --prune`**, the common case (draft):

```
prune> deleting 43 object(s) that left the build
ScaledObject.keda.sh/worker@app> deleting, waiting for finalizer.keda.sh
ScaledObject.keda.sh/worker@app> deleted (0.2s)
Deployment/keda-operator@keda> deleted
...
Deploy complete: 0 created, 3 configured, 78 unchanged, 0 failed, 43 deleted
```

**The stuck case** (draft):

```
waiting> ScaledObject.keda.sh/worker@app: being deleted for 60s, waiting for finalizer.keda.sh (budget 180s)
ScaledObject.keda.sh/worker@app> failed: still being deleted after 180s, waiting for finalizer.keda.sh.
  Deployment keda/keda-operator handles this kind and has 0 of 1 pods ready.
prune> kept 38 object(s) the ScaledObject needs until it is gone, including Deployment keda/keda-operator
Deploy failed: 0 created, 3 configured, 78 unchanged, 1 failed, 4 deleted, 38 not deleted

Next: get keda-operator running again, then run `kix deploy keda --prune`.
If you want to abandon what the finalizer cleans up, remove it yourself (Kix never does):
  kubectl -n app patch scaledobject worker --type=merge -p '{"metadata":{"finalizers":null}}'
```

Exit 1, the record is `Degraded`, and the 39 objects stay recorded as orphans, so the next `deploy --prune` or soft `kix gc` finds them.

**`kix status keda`** (draft). Status reads every object attributed to the Kix cluster already, so it can list the ones that left the build and are still being deleted:

```
keda: Degraded, deployed 4m ago
  ...
  Left the build, still being deleted:
    ScaledObject.keda.sh app/worker   for 4m, waiting for finalizer.keda.sh
80 resources: 80 ok. 1 object that left the build is still being deleted.
```

Exit 2. An object of the current build that is being deleted reads `not ready: being deleted for 2m, waiting for db.app-db. The next deploy creates it again once it is gone.` and counts as a problem under every check, as `missing` does.

**`kix gc keda --full-scan --dry-run`** (draft):

```
Objects to delete (1 left the build, still on the cluster):
  app ScaledObject/worker   being deleted since 15:54, waiting for finalizer.keda.sh
```

`kix gc` itself waits like deploy, in the same order, and exits 1 on a delete that does not finish. It gains `--timeout`.

### JSON (all additive, except one meaning, see section 9)

- **Deploy log:** a delete node goes `running` when the request is sent and `ready` when the object is gone. `waiting` lines carry a new phase `deletion`. A stuck delete is `failed` with detail `{"deletion_unfinished": {"elapsed_ms", "finalizers": [...], "controller": "<id>"?, "message"}}`. Orphans kept behind it are `cancelled` with `because: {"predecessor_failed": ...}`, as dependents of a failed apply are.
- **Plan:** `PruneEntry` gains `finalizers` (list), `deleting_since` (time, when already being deleted), and `controller` (resource id, when its kind declares one).
- **Status:** `Problem` gains `deleting`, `ResourceStatus` gains `deleting_since` and `finalizers`, `ClusterStatus` gains `leaving` (objects that left the build and are still on the cluster being deleted), and `Summary` gains `deleting`.

Under A, the same screens appear without the plan column, the `waiting>` lines, or concurrency. Under C alone, nothing on screen changes.

## 6. Hard cases

- **The operator was gone before this run.** The finalizer never clears. Kix waits out the budget and fails, naming the finalizer. With C, it also checks the declared controller and says "Deployment keda/keda-operator is not on the cluster". Recovery is the same: deploy the operator again, or remove the finalizer yourself.
- **A custom resource whose operator Kix does not manage.** Kix deletes nothing it would need, so only waiting matters. `controller` on `scope.mkCRDRef` may name an import marker, which lets the message say whether the imported workload is ready.
- **Namespaces and CRDs.** Kix never deletes them, and this design keeps that. It helps the case Kix leaves to the user: once a deploy has removed every custom resource and waited for each, a later `kubectl delete namespace` has no Kix finalizers left to hang on. Status and readiness treat a Namespace being deleted like any other object being deleted, so an apply into it fails clearly instead of with "namespace is being terminated".
- **`foregroundDeletion`.** Kix deletes with `Background`, so it never adds this finalizer. gc moves to `Background` too, so all paths agree. An object someone else deleted in the foreground waits for the objects it owns; the message says "waiting for the objects it owns to be deleted first" instead of a generic finalizer line.
- **Kubernetes' own finalizers.** A short table in `wait_gone` explains the documented ones: `kubernetes.io/pvc-protection` ("a pod still mounts it"), `kubernetes.io/pv-protection` ("a claim is still bound to it"), `foregroundDeletion`, `orphan`. Kubernetes defines these names, so the table is no guess. A PVC behind a Deployment that Kix deleted in the same run waits for its pods' grace period, then goes.
- **Stateful objects.** Waiting changes nothing about which objects get deleted. The migration gate and `--accept-migrations` still decide that before the run. A Database that is deletion-protected in its operator still goes in milliseconds.
- **`kix rollback --prune`** runs the same engine, so it waits the same way.
- **The operator.** Its reconcile uses the same scheduler, so deletes wait there, inside its fixed timeout. Its Activation teardown (`delete_in_order`) becomes "delete what is ready to delete, requeue until the rest is gone", and keeps its finalizer meanwhile, emitting a Warning Event that lists what is still being deleted. How to give up is question 5.
- **Deletes that span two deploys.** A stuck object stays recorded as an orphan (`orphans_left` true; in doc 175's terms, the kept-orphans revision lists it because it is still live). The next prune sees `deletionTimestamp`, does not send the delete again, and waits. The plan shows "already being deleted since 15:54".
- **The object comes back into the build while it is being deleted.** The apply waits for it to be gone, then creates it, and the plan shows the step as a recreate with that reason. This is the arc case: the new controller deletes old runner sets during an upgrade.
- **The deploy lock of doc 175.** A deploy holding the lock renews it while a delete waits, as it does before each delete.
- **Removing finalizers.** Kix never removes one, on any path. The failure message prints the `kubectl patch` command and says what the user gives up (the external cleanup the operator would have done, such as a database or a cloud resource). Whether Kix should offer its own command is question 2.

## 7. Status, drift, and readiness for objects being deleted

- **Readiness:** an object with `deletionTimestamp` is not ready, whatever its status says. Doc 176 settled this without asking. The reason text names the finalizers.
- **Apply onto it:** wait for it to be gone (`wait_gone`, same budget), then create. Never server-side apply onto it and report ready, because the object will vanish after the deploy finishes. `deploy --reconcile` follows the same rule.
- **Status:** `deleting` is its own problem, reported by every check, because neither presence, content, nor readiness describes it alone: the object is present, may hold the right fields, and will soon be missing.
- **Drift:** a drift check does not report an object being deleted as `changed`. It reports `deleting`, which is the more useful fact.
- **Objects that left the build:** status lists those being deleted (section 5) and counts them as problems. Orphans that a warn-only deploy kept and that nobody is deleting stay out of status, as today.

## 8. Recommendation and plan

Build D: deletes become nodes with a "gone" verdict owned by one `wait_gone`, and `scope.mkCRD` names its controller, so the operator always outlives the resources it must finalize. A delete that does not finish within `--timeout` fails the deploy, names the finalizer and the workload that should clear it, keeps everything the stuck object needs, and stays recorded for the next prune. Status, readiness, and gc all read `deletionTimestamp`, so no command calls a Terminating object ok. Kix never removes a finalizer itself.

### Phase 1: make the silent cases loud (S, about 400 lines with tests)

1. `wait_gone(api, rid, uid, budget, cancel, on_status)` in `cluster/readiness/` beside `wait_for_ready`, with the finalizer table. `recreate_in_place` calls it and matches by uid.
2. `Run::prune` (`scheduler/mod.rs`): after each `Pruned::Deleted`, call `wait_gone`. On timeout, count a failure with the finalizers, set `orphans_left`, and skip the orphans the stuck object depends on (walk `prune_order`'s graph). `PruneGuard::delete` returns a new `Pruned::AlreadyDeleting` for an object with `deletionTimestamp` and sends nothing.
3. Readiness: `check_readiness` and `not_ready_reason` return not ready for `deletionTimestamp`. This alone fixes `status` and `--reconcile` for objects in the build.
4. Line log: `prune_lines` says `will be deleted` under `--prune`; a delete node prints `deleted` where it printed `ready`.
5. gc: `delete_resources` waits through the same function and passes `Background`; full-scan rendering adds "being deleted since".

Tests: unit tests for `wait_gone` against `FakeApi`, which needs to honour finalizers (a delete sets `deletionTimestamp`, removing the last finalizer deletes); engine tests with a scripted `ResourceIo` whose prune leaves one object finalizing; readiness tests for the new rule. The kind test needs no operator: deploy a ConfigMap that depends on a Secret, add a finalizer `test.kix.run/hold` with `kubectl patch`, remove both from the build, run `deploy --prune --timeout 10s` and expect exit 1, the finalizer named, and the Secret still present; remove the finalizer and expect the next `deploy --prune` to exit 0 with both gone.

Change records: one `error` record, because a deploy, rollback, or gc that used to report success now fails when a delete does not finish or an object in the build is being deleted. The message carries the record's id. One `fixed` record for the log lines and status.

### Phase 2: deletes as scheduler nodes (M, about 1,000 lines)

`scheduler/plan.rs` emits `Delete` nodes with reversed orphan edges after a barrier on the apply nodes; `node.rs` runs them through `wait_gone`; the watchdog gets the `deletion` phase; `stream.rs`, `deploy_log.rs`, and the pretty renderer handle `running` and `failed` deletes; the JSON schemas gain the fields of section 5 (`KIX_WRITE_SCHEMAS=1`), and the deploy log's `SCHEMA_VERSION` moves (section 9). Status gains `leaving` and `deleting` (`cluster/observe.rs` already lists the objects). The plan gains the prune column. gc gains `--timeout`. The operator's teardown requeues instead of dropping its finalizer. Records: `added` for the fields and flag, `note` that deploys with `--prune` now take as long as finalizers need.

### Phase 3: the controller declaration (S in the library, M across packages)

`controller` on `scope.mkCRD` and `scope.mkCRDRef` (`kix/lib/core/resource.nix` `mkCRDBuilders`, `kix/lib/scope/builders.nix`), added to each resource's dependencies like `crRequires`. A unit test beside `lib-crd-cr-requires.nix`. The 15 native packages, then the keda and db-operator branches (their `crRequires = [ self.operator ]` becomes `controller`). If question 3 says required, an `error` record with its id in the build error; otherwise `added`. The plan's "0 of 1 pods ready" warning reads the declared controller.

### Docs and skills

- `docs/src/content/docs/reference/cli/`: `deploy.mdx` (prune step 6, `--timeout`), `gc.mdx`, `status.mdx`, `plan.mdx`, `rollback.mdx`, `operator-mode.mdx`, `exit-codes.mdx`.
- How-tos: `operate-a-cluster/garbage-collect-stale-resources.mdx`, `operate-a-cluster/deploy-with-dry-run-timeouts-pruning-and-log-tui-output-modes.mdx` (a section "When a delete does not finish"), and drop the manual steps from `package-task-guides/install-mayastor.mdx` and the arc package headers once phase 3 covers them.
- `reference/secrets-crds-and-rbac.mdx` for `controller`; `explanation/the-dependency-graph.mdx` for delete order.
- `cli/README.md`: scheduler, prune, readiness, `deploy_log.rs`, gc, status.
- Skills: `package-authoring` and `package-review` (every `scope.mkCRD` names its controller), `kix-migration`.
- `ROADMAP.md`: tick the finalizer item; note that delete nodes are the base for interleaved prune waves.

## 9. Versioning

- A deploy that printed `0 failed` with a stuck object now exits 1 after the budget. The same definition gives a different result, and the result shows an error with a next step, so it takes an `error` record. It is also a fix, but CLAUDE.md asks what a user who upgrades gets, and a CI job that passed now fails.
- In the deploy log, `kind: delete` with `state: ready` meant "request accepted" and will mean "gone". That changes what a value means, so the log's `SCHEMA_VERSION` moves in phase 2. Phase 1 keeps the event shape and only emits it later.
- No change to cluster state: no new annotation, no change to records. A stuck object is recorded with the existing `orphansKeptFrom`. No `state = true`, no required stop.
- Deploy time: for objects without finalizers, one read per deleted object in phase 1, and fewer round trips than today in phase 2. With finalizers, the deploy takes as long as the operator does, which is the time the user needs anyway.

## 10. Questions for the maintainer

1. **When Kix deletes an object and it does not go away, should the deploy fail?** Kubernetes deletes in two steps. Kix sends the delete, and the object stays until every "finalizer" on it is removed, usually by the operator that made it, which first cleans up something outside the cluster (a database, a scaler). Today Kix counts the object as deleted as soon as it sends the request. The proposal is that Kix waits up to the `--timeout` budget (default 3 minutes without progress) and, if the object is still there, exits 1, says which finalizer it waits for, and does not delete the things that object still needs, such as its operator. The alternative is to finish with exit 0 and a warning. **Recommended: fail.** A warning is how the KEDA test ended with a frozen workload and a green deploy.

2. **Should Kix ever remove a finalizer for you?** Removing a finalizer by hand makes Kubernetes delete the object at once, and the cleanup the operator would have done never happens: a database stays, a scaler's leftovers stay. The proposal is that Kix never does this. When a delete is stuck, it prints the exact `kubectl patch` command and says what you give up. The alternative is a Kix command, such as `kix gc --remove-finalizers <object>`, that asks for confirmation. **Recommended: no Kix command for now.** Printing the command keeps the irreversible step visible and costs nothing; a command can come later if users ask.

3. **Should every package that defines a custom resource type have to name the workload that handles it?** Kix deletes things in the reverse of the order it creates them, using the links between objects. A custom resource is linked to its type definition, but not to the operator that handles it unless the package author adds that link by hand, and most do not. The proposal adds a `controller` setting where the type is defined, so the link exists for every resource of that type. If it is required, packages outside this repository that define types fail to build until they set it (or set it to `null` when the package ships only the type). If optional, they keep working and keep the risk. **Recommended: required.** The build error names the setting, and a missing link is exactly how this bug stayed silent.

4. **Should that same link also make Kix wait for the operator to be ready before it creates resources of its type?** One link orders both directions: create the operator, then its resources; delete the resources, then the operator. Today some packages want only the create order (a webhook check), and the link makes a deploy wait a little longer on first install. The alternative is a link that orders deletes only, which is a second kind of link to explain. **Recommended: one link for both.** Creating a resource before its operator runs has its own failures, which `crRequires` already exists to prevent.

5. **When the Kix operator removes a deployment and some objects will not go away, should it keep trying?** The operator marks its deployment record so that Kubernetes asks it to clean up before the record disappears. Today it deletes the objects, ignores any that fail or stick, and lets the record go, so nothing names the leftovers. The proposal is that it keeps the record, retries until the objects are gone, and posts a warning on the record that lists them. You give up by deleting the leftovers or removing the record's own finalizer with `kubectl`. **Recommended: keep trying.** It is the same rule as the deploy, in the operator.

## 11. In the code, and not expected

- A stuck delete clears the record's memory of the orphan: it counts as pruned, `orphans_left` stays false, and `orphansKeptFrom` drops its build. That is why only `--full-scan` found the ScaledObject.
- The prune emits `Verdict::Ready` for a delete request, which is where the log's `ready` comes from.
- Deploy prunes with `Background`, and gc and the operator delete with each kind's default.
- Recreate already waits for a delete, for 30 seconds, by name rather than uid, and counts a read error as "gone".
- Prune is serial, each call under its own 60-second limit, so one slow API call holds every later delete.
- `prune_order` keeps edges between orphans only and falls back to name order on a cycle, silently.
- The KEDA log printed the `prune> deleting 4 object(s)` block twice in one deploy. Not investigated.
