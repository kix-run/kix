# 136: Health probe Jobs, the plan for the seven blockers on #77

**Status:** Implemented (Nix half in kix-run/kixpkgs#77, engine half in #79, both merged 2026-09-08)
**Shipped as planned, with two changes:** `kix.healthCheck` is marked experimental on #77 and may be removed if the trial clusters do not find it useful; the planner tag stayed `recreate` (the reserved Stage E transition) while the policy is named "rerun" in output. Items 8 to 10 (shared helpers, more probes) and the open questions live in `ROADMAP.md` (the `kix.healthCheck` entry and the `lib.functionArgs` entry).
**Related:** `81_deploy_as_lifecycle_engine.md` (Recreate transition, structured verdicts), `122_runtime_content_drift.md` (TTL'd Jobs are not drift), `121_netpol_as_plugin.md` (where a Job's egress edge is derived), `115_pod_spec_hardening_pass.md` (the probe pod goes through it), `111_operator_experience.md` (halt and report)
**Source:** PR kix-run/kixpkgs#77, "Required before this could merge", items 1 to 7. Items 8 to 10 (shared helpers, docs, which packages get probes) are not planned here. Four things the list did not have are at the end.

`kix.healthCheck` renders a Job that runs a Python file against addresses passed in as env vars from `out.*` values. It works on stage2. Each section states what the code does today, with file and line, then the decision, the work, and the test that proves it. The sequence at the end groups the work into pull requests.

The first draft of this plan put a content hash in the Job name so a changed probe would be a new resource. The red team showed that this churns the derived policy name (the CNP is named after the Job, `kix/lib/plugins/netpol/derive.nix:72,87`), leaks a hash-named ConfigMap per edit under the default warn-only prune, turns every script edit into a delete plus add in the preview, and still leaves a failed probe stuck until its TTL. One engine rule replaces it and covers items 1 and 2 together.

## The rule: a probe Job whose identity changed is recreated

A probe is run-once and cheap. If Kix has a probe Job to apply whose `kix.dev/identity-hash` differs from the one the cluster last ran, the right action is never "patch it", it is "run it again". The engine deletes the live Job when there is one (foreground, so its pod goes with it), waits until it is gone, then creates the new one. The identity hash covers the sealed manifest, its `depends-on` annotation and everything it depends on (`kix/lib/core/resource.nix:260-275,337-345`), so "changed" means the probe changed, or something it checks changed, or something upstream of that changed. A probe with an unchanged hash is `Skip`, as today, and does not run, with one exception: a skipped probe whose live Job is in a failed state is recreated, so a probe that failed against a degraded cluster runs again on the next deploy or rollback without a manual delete.

The rule is opt-in by annotation, not by kind. The helper stamps `kix.dev/rerun = "on-change"` on the Job and the engine acts only on that. Applied to every Job it would re-run the stackgres bootstrap SQL (`kix/packages/stackgres-database/default.nix:349`), regenerate ingress-nginx's admission certificate (`kix/packages/ingress-nginx/default.nix:745,803`) and kill a long migration Job whenever anything upstream of them moved, because a `depends-on` change alone changes the identity hash.

This is doc 81 §5's `Recreate` transition for the one case where the decision needs no registry and no cost to weigh. It lands as a planner tag plus an executor path now and folds into the planner's registry when doc 81's split happens.

## 1. A changed probe must replace its Job

**What the code does.** A Job's pod template is immutable. Applying a changed probe returns a 422 that `classify_apply_error` turns into `ApplyError::ImmutableConflict` (`cli/kix/src/cluster/apply.rs:498-536`). The scheduler recovers by delete and re-apply only when the resource is in the orphan set (`cli/kix/src/cluster/scheduler.rs:1280`). The orphan set holds old-side resources whose kind, namespace and name match nothing on the new side (`apply.rs:186-196`). A resource that is in the plan is therefore never in the orphan set, and the recovery branch cannot run on a real deploy. Only a unit test that hand-passes overlapping sets reaches it (`scheduler.rs:2246-2272`). The error text tells the user to "include this resource in the prune set", which is not possible.

The same shape traps a failed probe. `backoffLimit = 0` leaves the Job in `status.failed = 1`. The activation is not finalised, so the next deploy diffs against the last good activation, gets `Apply`, and the server-side apply is a no-op. `scan_terminal` then classifies the still-failed Job as terminal again (`cli/kix/src/cluster/readiness.rs:604-616`). The deploy stays red for the whole TTL unless someone deletes the Job by hand.

**Decision.** The rule above. The Job keeps its stable name `${name}-health`.

**Work.**

- Planner: where `ChangeAction::Apply` becomes `TransitionKind::Apply` (`scheduler.rs:111`), a manifest carrying `kix.dev/rerun` becomes `TransitionKind::Recreate`, which exists and is set nowhere today. That is what gives the preview its line: "recreate Job vm-agent-health (run again)".
- Executor, the apply transition (around `scheduler.rs:1276`): for a `Recreate` node, `get_opt` first. Absent (first deploy, TTL-reaped, hand-deleted, dry run) means plain `apply`. Present means `recreate_in_place` (`cli/kix/src/cluster/ops/kube.rs:233-279`), which today returns an error on a 404 from the delete (`kube.rs:245-247`) and, after its 30-second poll (`kube.rs:37,254-265`), applies regardless. Two fixes there: a `NotFound` on delete is success, and a Job still carrying `deletionTimestamp` after the poll returns a distinct "still terminating" error instead of an apply that fails with an unexplained 422.
- Executor, `Skip` nodes with the annotation: `get_opt`, and if the live Job has a `Failed` condition, take the `Recreate` path.
- The `ImmutableConflict` branch keeps its orphan-set guard for other kinds. Its error text at `apply.rs:51-53` stops recommending the prune set for Jobs.
- The scripted `ClusterOps` fake gets the four cases.

The Job manifest has no `spec.selector`; `mkJob` only emits one when the caller passed it (`kix/lib/scope/builders.nix:305-308`). The pod lookup in the engine works from the live object, which carries the controller's `batch.kubernetes.io/controller-uid` selector, and a recreated Job has a new uid, so no pod from the previous run is picked up.

**Tests.** Engine: a live Job with a different identity hash is deleted, waited for, created, and reported ready from the new completion; an absent Job is created without a delete; a skipped Job in `Failed` is recreated; a Job still terminating after the poll fails with the distinct error. Live, on stage2: change the age limit and deploy, the Job re-runs; set a wrong replica count, deploy, it fails; fix it, deploy, it runs again without a manual delete.

## 2. When a probe re-runs

**What the code does.** `kix deploy` diffs the new manifest set against the manifests of the cluster's active Activation, not the live objects (`cli/kix-cli/src/commands/deploy.rs:119` calls `detect_changes` on the old set loaded from the Activation record). An unchanged identity hash is `Skip` (`apply.rs:161-165`). Address values such as `out.url` carry the target's seal path (`resource.nix:377-381`), and the seal covers that resource's own dependencies, so the probe's hash is sensitive to the whole subgraph upstream of what it checks.

Two things fall out. A probe removed by `ttlSecondsAfterFinished` or by hand is not re-created on the next deploy unless its hash changed, which is right: nothing changed. And without the rule above, a dependency change inside the TTL window re-applied the same pod template under the same name, the old completion satisfied `status.succeeded >= 1` (`readiness.rs:1128-1134`), and the deploy reported the probe ready without running it. The rule closes that.

The Activation's identity is a store hash over the Activation's own references, computed at eval time (`kix/lib/core/activation.nix:62-80`, `cli/kix/src/manifest/stamp.rs:80-93`). The Job is upstream of it, so "re-run on every deploy" cannot be expressed by naming, and it is not offered.

`kix health` already treats a TTL'd Job as `Reaped`, not `Missing` (`cli/kix-cli/src/commands/health.rs:395-411`). `kix drift` iterates live objects and has no notion of a missing resource (`cli/kix/src/cluster/drift.rs:67-75`). Nothing to do on either.

`kix rollback` re-applies the previous activation through the same scheduler (`cli/kix-cli/src/commands/rollback.rs:356`). Under the rule, the previous probe Job differs in identity from the current one whenever the probe or its targets differ, so it is recreated and runs against the rolled-back state. When nothing about it differs it is skipped, and the failed-live exception then recreates it if the current activation left it failed. Rollback no longer depends on whether the TTL has passed.

**Decision.** A probe runs whenever its Job's identity differs from what the cluster last ran, in deploy and in rollback, and never otherwise. Someone who wants a fresh run for its own sake changes an input, such as `retryFor`.

**Work.** The helper comment and the HANDBOOK entry state the rule in one sentence: "the probe runs again when it, or anything upstream of what it checks, changes".

**Tests.** Eval: changing the ServiceRef the env points at changes the Job's identity hash (`t60-healthcheck-identity-follows-target`). Live, on stage2: deploy, deploy again with no change, the Job is skipped; change the VMAgent replica count, the Job runs.

**Open.** `ttlSecondsAfterFinished` stays at 3600. A longer TTL only serves someone reading `kubectl get jobs` later.

## 3. Pass dependency-injected packages through

**What the code does.** Dependency discovery reads `builtins.functionArgs` of each build entry lambda (`kix/lib/eval/resolve.nix:223-241`) and binding uses the same function (`kix/lib/eval/instance.nix:258-273`). A helper cannot build a lambda with caller-chosen formal arguments: `lib.setFunctionArgs` returns a functor, and `builtins.functionArgs` on a functor throws. There is no other declaration channel. But a build entry that names `deps` receives the instance's whole resolved dependency set (`instance.nix:270`), `deps` is a system name that declares nothing (`resolve.nix:10-18`), and the HANDBOOK documents it (`docs-legacy/HANDBOOK.md:344`).

**Decision.** The helper's lambda names `deps` and passes it to `env`. The package writes `VMSELECT_URL = deps.vmCluster.out.serviceUrl` and the `healthInputs` part goes away. Some entry of the package must declare the dependency, which is true whenever the probe checks something the package uses. A probe-only dependency would need a one-line declaration in the main entry; acceptable until a real case appears. The enabling change for a `deps = [ "vmCluster" ]` list on the helper is switching the seven `builtins.functionArgs` sites (`meta.nix:81`, `mkFlake.nix:63`, `eval/instance.nix:261`, `eval/import.nix:165,201`, `eval/resolve.nix:212,234`) to `lib.functionArgs` and applying through `__functor`. Deferred, noted in `ROADMAP.md`.

**Work.** `compose.nix`: lambda pattern `{ self, config, scope, lib, deps, ... }`, `env { inherit self config deps; }`. Both VM packages: drop `healthInputs`, read from `deps`.

**Tests.** The fixture `clusters/test-victoria-metrics.nix` renders both Jobs with the same env values as before. `t61-healthcheck-deps-arg`: a probe reads a Service from `deps` and the Job's `depends-on` carries the ServiceRef's store path.

## 4. Network policy edge on an enforcing cluster

**What the code does.** The edge exists by construction. `Job` is in `terminatorKinds` (`kix/lib/core/facts.nix:76-81`), `scope.mkJob` seals through the same `sealWorkload` as Deployments (`kix/lib/scope/builders.nix:327-331`), edge analysis serialises the whole workload so an `out.url` anywhere in the pod template counts (`kix/lib/eval/edges.nix:110-193`, `kix/lib/eval/instance.nix:128-136`), and the netpol plugin renders a CNP named `<instance>-job-<job name>-egress` from it (`derive.nix:72,87`), for the agent package `vm-agent-job-vm-agent-health-egress`. The CNP and the DNS dependency go into the Job's `requires`, so the policy is applied before the pod starts. What is missing is proof: no test in `kix/lib/tests` uses a Job, and no cluster with an enforcer has run a probe. The stub enforcer (`kix/lib/tests/default.nix:358-440`) is kind-agnostic and needs no change.

**Decision.** Add the test, then run it for real on a Cilium kind cluster.

**Work.**

- `t62-healthcheck-job-egress`: a package with a Service and a `kix.healthCheck` whose env is `svc.out.url`, under the `netpolOn` fixture (`tests/default.nix:660-665`). Assert the CNP `app-job-app-health-egress` exists with one `service-egress` rule whose selector and namespace are the Service's, its `endpointSelector` is the probe pod's labels (see "Found during planning" A), and the Job's `depends-on` lists the CNP with the `requires:` tag. A sibling case wraps the value in `kix.facts.refOnly` and asserts no CNP.
- Live: bring up ludo-kind with Cilium (`demo/deploy-ludo-kind-*.sh`), add the VM stack fixture with both probes enabled, deploy. Expected: default-deny on, probes pass. Then wrap the env value in `refOnly` and deploy again: the probe must fail with a connection timeout, which is the evidence that the deny is real and the edge is what let it through. Both outputs go into the PR.

## 5. Surface the probe's output in the deploy

**What the code does.** The failure line comes from `classify_workload_terminal` (`readiness.rs:604-635`): `JobBackoffExceeded: Job failed 1 times (backoffLimit=0)`. `scan_terminal` returns on that workload-level hit with an empty pod list and never fetches pods (`readiness.rs:710-716`); the pod-level classifier is only reached for kinds without a workload signal and requires three restarts (`readiness.rs:425,560`), which a `restartPolicy: Never` pod never has. No code in the CLI reads container logs or `state.terminated.message`; `kix logs` shells out to `kubectl` (`cli/kix-cli/src/commands/logs.rs:39`).

Kubernetes has a channel for this. With `terminationMessagePolicy: FallbackToLogsOnError`, the kubelet copies the last 2048 bytes or 80 lines of the container log into `status.containerStatuses[].state.terminated.message` when the container ends with a non-zero exit and wrote nothing to its termination file. The probe prints and flushes every round, so the tail holds the last round's lines. No log API call, no extra RBAC, no file the process has to be able to write.

Two limits shape the decision. The probe must end itself: when `activeDeadlineSeconds` fires, the Job controller deletes the pod, so there is no pod and no message to read, and the container gets SIGTERM, which Python does not survive to write anything. And a manual write to the termination file, if it is non-empty, replaces the log fallback rather than adding to it, and the file's writability for a non-root process is not established.

**Decision.** The log fallback alone, no manual write. The probe exits non-zero on its own budget, well inside the Job deadline, and prints a last line on SIGTERM so a deadline kill that does reach the log says why. The engine reads the message from the pod after a Job-level failure. Success output stays in the pod log; the deploy line for a passing probe does not change.

**Work.**

- `compose.nix`: `terminationMessagePolicy = "FallbackToLogsOnError"` on the probe container. `timeoutSeconds` default rises to 180 and the comment states the contract: the script's retry window plus one worst-case round must fit inside it. With `retryFor = 90` and four checks at a 10-second HTTP timeout each, the worst case is 130 seconds, which today's 120 does not cover.
- Both `health-check.py`: the retry loop already exits 1 at its deadline. Add a SIGTERM handler that prints "killed before the retry window ended" and exits 1. Part of item 8's shared module later.
- Engine: `scan_terminal` (`readiness.rs:710-716`), on a Job-level hit, lists the Job's pods by the live object's selector and appends `state.terminated.message` (or `lastState`) of the `probe` container to the detail. `NodeDetail::ReadinessFailed` carries it; the pretty renderer (`cli/kix-cli/src/commands/deploy.rs:878-884`) prints it indented under the warning line; the line log (`cli/kix-cli/src/commands/deploy_log.rs:73-78`) prints it after `FAILED:`. Truncate at 20 lines with a "see kubectl logs" tail.

**Tests.** Engine: a scripted-fake test with a failed Job and a pod whose `terminated.message` holds two `FAIL` lines; the rendered failure includes them. Live, on stage2: set `AGENT_REPLICAS` wrong through the option, deploy, and the deploy output shows the `FAIL` line naming the count. Confirm on stage2 that the message is populated for the non-root container from item B.

**Open.** Whether the operator (doc 62) should emit the message as an Event. Same data, second renderer; not blocking.

## 6. Image policy

**What the code does.** There is no cluster-level image policy. `extraImages` exists only for images an operator spawns at runtime, and `kix images` already walks Job containers (`cli/kix-cli/src/commands/images.rs:92-131`), so the probe image is listed for mirroring without any declaration. No package pins by digest; ingress-nginx has the plumbing (`digest = null`, appended as `@${digest}`, `kix/packages/ingress-nginx/default.nix:91-106,251-260`). The scorecard warns on `latest` (`kix/lib/rules/security.nix:108`). `ROADMAP.md` lists the repeated `{ repository; tag; pullPolicy }` convention as a thing to standardise. `kix compliance sbom` reads `@sha256:` refs when present.

**Decision.**

- The helper takes one `runtime` argument, `{ image = { repository; tag; digest; }; interpreter = [ … ]; }`, replacing the separate `image` and `interpreter`. `kix.healthCheck.runtimes.python` is the default, `docker.io/library/python:3.13-slim` pinned by digest. A `shell` runtime on `curlimages/curl` sits next to it so the pair is not a one-off. A package may pass its own `runtime`.
- No cluster-level override. Air-gapped clusters mirror what `kix images` lists and redirect at the registry, which is how every other image in the cluster is handled; a per-helper cluster option would be a second escape hatch next to `cluster.factBehavior` with no driver behind it (doc 47 is blocked on demand).
- Which digest. The multi-arch index digest, which is what containerd resolves. The kind local-registry script strips `@sha256:` and re-tags through the docker daemon (`demo/kind-local-registry.sh:165-180`), so a kind node pulling by index digest from that mirror gets a 404. The script moves to `crane copy`, which copies the index as is. That is part of the live proof for item 4, since it runs on kind.
- Bumping is a documented manual step: `crane digest docker.io/library/python:3.13-slim`, edit the constant.

**Work.** `compose.nix` runtime attrset and the two runtime constants; both packages unchanged (they use the default). The image rendered as `repository:tag@digest`.

**Tests.** Eval: default rendering shows the digest form (`t63-healthcheck-runtime-default`); a package-supplied runtime renders as given. `kix images` on the fixture lists the pinned reference.

## 7. The script in the manifest

**What the code does.** The script is `command[2]`, one string of about 150 lines, in the Job's pod template. It works and the identity hash covers it. It is unreadable in a preview diff and in `kubectl get job -o yaml`.

**Decision.** The script lives in a ConfigMap with a stable name, `${name}-health-script`, mutable, with the file under `data."health-check.py"`, mounted read-only at `/probe`. The command becomes `interpreter ++ [ "/probe/health-check.py" ]`. The Job references the ConfigMap by store path through the mount, so a script change changes the ConfigMap's seal, therefore the Job's identity hash, therefore the Job is recreated under the rule. The preview shows the script edit as a readable diff of one ConfigMap and a "recreate Job" line. Nothing accumulates: an edit updates the ConfigMap in place. It is a second part, `${partName}Script`, so orphan detection and `self` references keep working. Not `immutable = true`: that would need hash names and bring back the leak.

**Work.** `compose.nix`: build the ConfigMap with `scope.mkResource`, mount it with `kix.mount.configMap self.${partName}Script { mountPath = "/probe"; readOnly = true; }` (`compose.nix:295-319`; the volume's `configMap.name` keeps the store-path context, so the seal reaches `depends-on` and the identity hash) and `kix.withMountsOn "probe"` applied to the attrset before `scope.mkJob`. `withMountsOn` rather than `withMounts` so a future sidecar does not trip the single-container check (`compose.nix:425`). Both `lib.fix` parts come from the same entry, so the reference is fine. Each runtime's `interpreter` takes a path, not `-c`. A ConfigMap volume is populated when the pod is created, and the ConfigMap is applied before the Job by the `depends-on` edge, so a recreated probe always reads the new script. Fixture and PR body updated with the new rendering.

**Tests.** Eval: the Job's `depends-on` carries the ConfigMap's store path, the data key holds the file verbatim, and changing the script changes the Job's identity hash but not its name (`t64-healthcheck-script-configmap`). Live: stage2 deploy, both probes pass, `kubectl get cm` shows the file.

**Open.** Whether inline should remain available for a one-line probe. Not offered; one shape is easier to document and test.

## Found during planning

Four things the PR list did not have. A and B block the merge; C and D are decided above and listed here so they are not lost.

**A. The probe pod is selected by the package's Service.** The pod template's labels are `scope.selectorLabels` plus a component label (`compose.nix:546-548`). Any Service that selects on `scope.selectorLabels`, which is the documented convention, admits the probe pod as an endpoint for its lifetime and routes real traffic to it. The VM packages escape only because their Services are operator-authored. Fix: the pod carries its own labels, `app.kubernetes.io/name = "${name}-health"` and `app.kubernetes.io/component = "health-check"`, with no instance label shared with the package's workloads. The selector checks in `kix/lib/eval/validate.nix` cover Deployment, StatefulSet and DaemonSet only (`validate.nix:471-479`); adding `Job` to that filter and a rule that a Job's pod labels are not a superset of any sibling Service's selector stops the next helper from making the same mistake. The CNP still targets the pod, because its `endpointSelector` is the template labels (`derive.nix:85-88`). Test: `t65-healthcheck-pod-not-in-service` renders a package with a Service on `selectorLabels` and asserts the probe pod's labels do not satisfy it.

**B. The probe pod fails the security scorecard and mounts a token it does not use.** `security.nonRoot` is an error and applies to Jobs (`kix/lib/rules/security.nix:25-37`). Building the fixture prints `nonRoot` and `readOnlyRootfs` findings for `vm-agent-health`; they are warnings only because the fixture downgrades `nonRoot` for grafana (`clusters/test-victoria-metrics.nix:120-127`), and that comment's claim that the VM packages pass at error is now false. A cluster with the stock rules cannot build with a probe enabled. Fix in `compose.nix`: `securityContext = { runAsNonRoot = true; runAsUser = 65534; runAsGroup = 65534; allowPrivilegeEscalation = false; readOnlyRootFilesystem = true; capabilities.drop = [ "ALL" ]; }`, `automountServiceAccountToken = false` on the pod (the probe talks to Services, never to the API server), `resources = { requests = { cpu = "50m"; memory = "64Mi"; }; limits.memory = "128Mi"; }`. Python on the slim image runs as 65534 with a read-only root once `PYTHONDONTWRITEBYTECODE=1` is set so it does not try to write a cache next to the script; it writes nothing else. Correct the fixture comment. Test: the fixture builds with `security.nonRoot` back at error.

**C. Retry after a failed probe.** Covered by the rule; the second engine test in item 1 is the proof.

**D. Rollback.** Covered in item 2.

## Sequence

Nix first, because it ships with #77. The engine rule second, in one CLI pull request, and #77 cannot merge before it because a changed probe hits the immutable conflict without it. Live proof last.

1. **#77, next commit set (Nix).** Items 3 (`deps`), 6 (runtime with digest), 7 (ConfigMap), 5's Nix half (`FallbackToLogsOnError`, termination-log write), A (labels), B (hardening, token, resources), and the one-sentence re-run rule in the helper comment and HANDBOOK. Tests t60 to t65. FEATURE-CATALOG and the kix-migration skill entries. `architecture.md` untouched (no eval change). Red team, then out of draft.
2. **CLI pull request.** The rerun rule (planner tag, executor path, the `recreate_in_place` fixes, the failed-live exception), the termination-message surfacing in `scan_terminal` (item 5), the scripted-fake tests, the corrected error text. Small enough to review in one sitting.
3. **Live proof.** stage2 for items 1, 2, 5 (change, no change, dependency change, forced failure and retry, termination message from the non-root container). A Cilium kind cluster for item 4, both directions, with the `crane copy` mirror from item 6. Outputs go into the PR.
4. Not here: item 8 (shared module) starts when the third probe is written; item 10 decides which package that is.

## What this plan does not decide

- The planner-side `Recreate` transition of doc 81 §5 for kinds other than Job. The Job rule is the first entry of that registry and moves into the planner when the split lands.
- Re-running probes on a schedule or from `kix health`. A probe is a deploy gate; continuous checking is monitoring's job.
- The `lib.functionArgs` switch that would let a helper declare its own dependencies. Recorded in `ROADMAP.md` with the seven call sites named.
