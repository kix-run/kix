# 176: Design read of the larger housekeeping themes

**Status:** Draft. A survey, written on 2026-11-23 by a design agent from code and documents only, with no cluster and no test run.
**Related:** `housekeeping/reviews/2026-11-23.md` (the review whose themes 4 to 14 this reads), `175_one_home_for_what_a_deploy_did.md` (the design for themes 4 and 5 and questions 2 and 3)

Type: analysis. It gives a design direction for ten themes of the housekeeping review and the questions each left for the maintainer.

## Answers given on 2026-11-24

1. **A plain `kix deploy` brings the whole cluster back to the build:** option (a). The plan labels a change that undoes an edit made outside Kix as "reverting drift", and an intended change has no label.
2. **Per-deploy notes leave the objects.** Doc 175 has the design. It differs from option (a) below: the object list is split into one `PackageInstanceRevision` per package instance.
3. **The deploy lock is one Kix-owned object per Kix cluster:** option (a). Doc 175 names it `ActivationHead`.
4. **Network intents leave package metadata:** option (a), stated on the workload, with outbound rules worked out from the addresses a workload reads.
5. **An instance's name does not satisfy a dependency:** option (a).

Nothing below is built. The sections that follow are the report as written, before these answers.

## Shared concepts

**The deployment record becomes the one home for what a deploy did (themes 4, 5, and part of 6).** Kix keeps this knowledge in three places today: annotations it writes on every object after each apply, the per-deploy record, and builds on the deploying machine. Each command picks its own mix, so they disagree. If the record holds the list of objects, their hashes, who is deploying now, and which Kix wrote last, every command and the operator can plan from the same facts. Objects are then written once per deploy, which removes the race with operators and the ClickHouse Keeper restarts. The roadmap already says to pick one of the two places.

**A declaration lives on the object it describes (themes 8 and 9, and parts of 7 and 13).** Package metadata is read before the instance's settings exist, and it applies to the whole package. That one fact causes these problems:
- Network intents cannot read settings and land on every workload.
- Safety exemptions are listed even when the pods are not rendered.
- A Kubernetes version range cannot apply to one option.
- A package cannot claim a role for some clusters only.

Kix solved this once, for the availability ceiling, with the rule "package level for program limits, builder level for anything that depends on config or wiring". The same rule fits network intents, scorecard reasons, and version ranges.

**What an operator makes from a custom resource is declared once, where the resource type is defined (themes 6, 7, 8, 13, and 14).** Kix already takes five declarations there: readiness, failed states, network behaviour, quota use, and ceded fields. The open entries ask for the same kind of fact:
- Which pods the operator creates, for network policy and for waiting on their rollout.
- Whether a change needs the object replaced.
- Where the resource names a storage class.
- Which monitoring contract the type follows.

Doc 147 recommends this channel and notes that the pattern has shipped three times.

## Theme by theme

### 1. Deployment records have no lock and no note of which Kix wrote last (theme 5)

Two deploys of one cluster can run at once, and the second overwrites the first one's notes. A killed deploy leaves a record marked "deploying" until someone patches it by hand. The version check reads the Kix that built a record, which is wrong after a rollback or when the operator did the write.

The design: one small object per Kix cluster that holds the lock, the writer, and a pointer to the current record. The lock follows Kubernetes lease rules (holder, renew time, and expiry). A deploy takes it before its first write and renews it while it runs. When a lock has expired, the next deploy marks the dead run's record failed and carries on. Every write to this object uses compare-and-swap, so two deploys cannot both finalize. Whoever writes the cluster, the CLI or the operator, stamps its own version there.

Settled without asking:
- A deploy that cannot create its record stops before the first apply. Evidence: CLAUDE.md, "turn a breaking change with no error into one that shows an error".
- The operator and the CLI set the writer through one code path, and the required-stop check reads it. Evidence: `housekeeping/2026-11-20-record-names-the-builder-not-the-writer.md`.
- The docs stop claiming a refusal that the code does not make, until the lock ships.

Leaning (confirm or veto):
- After a failed deploy, `kix rollback` offers the build that is still active as its first target. That is the state the cluster was in before the failure.
- A rollback with no local copy of the current build rebuilds its baseline from live objects, as deploy already does.
- The downgrade override reaches the operator through the queued request, so one check owns the decision.
- The operator learns of a withdrawn Kix from a signed copy of the release index that the CLI leaves in the cluster (the entry's option 3).
- Two Kix clusters that render one shared object differently could each apply under their own field-manager name. Kubernetes would then report the disagreement as a conflict. This needs a test on kind before anyone relies on it.

Needs your answer: 3.
Size: M. It adds to what Kix writes into a cluster. Old records stay readable, so no required stop.

### 2. Five commands each decide what will change (theme 4)

`kix plan`, `kix plan --read-only`, `kix deploy`, `kix gc`, and the operator each work out the change their own way. The CLI compares the new build with the builds the records name. The operator compares the build with every live object. The read-only plan compares the build with a filtered view of live objects.

The design: one planner with three labelled inputs. They are the new build, the deployed builds named by the records, and drift (live objects that no longer match what Kix applied). Every command renders the same plan document, which already exists. The operator uses the same planner. The only difference left between commands is policy: whether drift is healed and whether orphans are deleted.

Settled without asking:
- One plan document for every command, with "not checked" typed apart from "nothing found". Evidence: `discussions/archive/157_kix_plan_primary_preview.md` section 3, shipped.
- What a build changes is decided from compiler outputs. Evidence: `cli/README.md`, "Baseline: what a plan compares against".
- An object that a new package adopts shows as a change to an existing object.
- A dry-run refusal counts as "not checked" when anything the refused object depends on changes in the same deploy. The dependency graph gives this, and it replaces the three special cases. Evidence: CLAUDE.md "Fixing bugs", and `housekeeping/2026-11-13-webhook-backend-counted-repaired-by-package.md`.
- A saved plan records the error policy and the failed records it folded in.
- The read-only plan becomes the same planner without the dry run, so the old comparison code goes.

Leaning (confirm or veto):
- Leftovers of a failed deploy get their own label in the plan and stop being called drift.
- Drift labels compare the server's form on both sides, using the hash Kix already stores.

Needs your answer: 1.
Size: L. If the answer to question 1 is "heal", the same definition gives a different deploy result, which needs a "no error" breaking record.

### 3. The deploy has no model for a change that cannot be made in place (theme 6)

Some fields cannot change on a live object: a Service's cluster IP, a Deployment's selector, and a PriorityClass value. Some operators also refuse or rewrite changes. Today these stop the deploy partway, and detection is a list of phrases from server messages.

The design: replacement is a planned step, shown in the plan before anything is written, as `discussions/81_deploy_as_lifecycle_engine.md` section 5 proposes.
- For built-in kinds, a table of fields that cannot change decides it by comparing the deployed build with the new build.
- For custom resources, the package declares "replace on change" where it defines the type.
- A replace deletes with cascade, waits until the object is gone, then creates.
- An object that holds data is never replaced automatically. It becomes a migration stop, as today.
- Prune waits for each deletion to finish, in reverse dependency order, so an operator outlives the resources whose finalizers it must clear.

Settled without asking:
- The phrase list stops being the decision. Evidence: CLAUDE.md "Fixing bugs" rules out heuristics.
- The engine takes no step the plan did not show. Evidence: doc 81.
- A rerun Job that will be deleted and recreated is not dry-run patched, so it cannot raise an ownership conflict.

Leaning (confirm or veto):
- A replace of an object that holds no data goes ahead once the plan has shown it, with no extra flag. Rerun Jobs already work this way.
- StackGres major upgrade: keep the ownership conflict as the prompt to update the definition, and make the message name the fix. Ceding the field would let a definition say 17 while 18 runs, with no error.
- KubeVirt volume templates: cede the list to the controller.
- A per-object "keep when removed" declaration sits beside the existing "holds data" marker.
- A renamed volume instance should raise a migration stop. Pairing by claim identity across instances needs its own small design.

Needs your answer: 2, for the annotations written after each apply.
Size: L. Additive for packages. No change to existing definitions.

### 4. Readiness trusts a status that is stale or says too little (theme 7)

Right after an apply, a controller's status still describes the old spec, so Kix can read "ready" too early. Separately, every wait is cut at 300 seconds whatever `--timeout` says, and an image pull error is judged final by matching kubelet wording.

The design: a status counts only when it is about the spec this deploy applied. Kix proves that by the controller's observed generation, or by a status change later than the apply as timed by the API server. Where a controller offers neither, Kix says the readiness is unverified. For custom resources, the package also declares which workloads the operator makes, and Kix waits for their rollout using Kubernetes' own status.

Settled without asking:
- The fixed 300-second cut goes. A wait ends on no progress for the `--timeout` period, on a terminal state, or on the whole-deploy limit. Evidence: doc 81 ("verdicts replacing wall-clock timeouts"), and two entries where `--timeout 20m` was ignored.
- A package states a slow first start with the standard `progressDeadlineSeconds` and startup probe. Evidence: CLAUDE.md, "Don't invent new fields".
- An object that is being deleted is not ready.
- The apply time comes from the API server's clock.
- One unavailable add-on API does not stop discovery, as with kubectl.

Leaning (confirm or veto):
- Image pull errors are not final, except the kubelet's structured "invalid image name" reason. The last pull message shows when the wait times out. This is the entry's option (a). A wrong image name then costs one timeout period.
- A wait on something made by a cancelled object ends with that object.
- The operator's fixed 300-second timeout becomes a value on the queued request.

Needs your answer: nothing.
Size: M. No change to cluster state. Deploys that failed at 300 seconds will now wait longer.

### 5. Network intents cannot say which workload, which port, or which peer (theme 8)

A package states extra network needs in its metadata. Those are fixed before settings exist and are applied to every workload of the package, so pods are opened wider than they need. Twenty-three packages work around this with a helper meant for operator-made pods.

The design, in two parts, both following how Kix already derives policy:
- **Outbound.** A value that names an address carries the fact that it is dialled, as Service addresses do today. An external host and port, an address range, or a public URL becomes such a value. The workload that reads it gets egress to that port only.
- **Inbound, and anything with no value to read.** The intent is stated on the workload it applies to, where settings are available. It can name the workload's own pods, an address range, or another resource as the peer.

Settled without asking:
- A consumer gets egress to the port in the address it reads, not every port of the Service.
- An exposed URL names the pods behind it, so an in-cluster client of the public URL gets a path to the ingress controller. Evidence: CLAUDE.md "Resources are rich objects", and `docs/src/content/docs/explanation/network-policy.mdx`.
- The DNS rule reads the DNS provider's namespace and labels instead of assuming `kube-system`.
- Pods that nobody declares stay closed under default deny. The cluster opens them with platform intents, which exist for this.
- Policies for a package's own pods are no longer labelled as operator-managed.

Leaning (confirm or veto):
- Narrow the API server rule to stated ports. Give metrics-server and the scrape rules explicit kubelet rules first.
- Flavours that import into `kube-system` must declare intents for the platform's pods there, or leave that namespace out of default deny.

Needs your answer: 4.
Size: L. It breaks every package with intents if the old form is removed (shown as an error).

### 6. Scorecard rules cannot accept a stated reason (theme 9)

Some findings are facts about upstream software, such as a binary with no health endpoint. They print on every build, so real findings are hard to see.

This theme is two problems.

- **Rules that are wrong.** The graceful-shutdown rule should accept the Kubernetes default. The selector rule should accept a selector taken from the workload itself through the supported cycle-breaking handle. Annotation domains should match by suffix. These are rule fixes.
- **Real exceptions.** A reason is stated on the builder call for the workload or Service it concerns, naming the rule and the container. The finding drops to info, and one listing shows every accepted reason. Rules that guard security errors keep the stricter registry of grants.

Settled without asking:
- A package's own statement takes effect and is listed in every build. Evidence: `kix/lib/unsafe.nix` and the rule that lists grants work this way.
- The statement sits on the builder call. Evidence: the availability ceiling in `ROADMAP.md`.
- Monitoring kinds are declared on the resource type (doc 147 option A). The doc recommends it and the pattern has shipped three times.

Leaning (confirm or veto):
- Chart-imported workloads take the reason on the chart import call, keyed by object.
- Two new rules: an image without a digest (warning), and host access without a declared Pod Security level.

Needs your answer: nothing.
Size: M. Additive.

### 7. Dependency resolution rules that need a decision (theme 10)

Kix matches a dependency by name against instance names, aliases, and roles. Four rules cause surprises: a name can capture a dependency by accident, `null` cannot mean "none", two candidates fail a consumer that never reads the dependency, and a provider cannot say it serves one consumer only.

The design: a dependency is satisfied by something that declares it provides that thing. Ambiguity is reported when the dependency is read. Exclusive use is declared and checked.

Settled without asking:
- A dependency key the package does not take is refused. Evidence: CLAUDE.md, turn a silent break into an error.
- A dormant optional instance resolves nothing.
- An instance never binds to itself. Evidence: `ROADMAP.md` open design questions.
- Contract checks run as the binding the package reads through, so the contract message wins over "attribute missing". Evidence: the secret-key check already works this way.

Leaning (confirm or veto):
- `deps.x = null` written in a cluster means "no provider". A key left out means "resolve automatically". This changes results with no error for a cluster that sets null conditionally, so it needs a "no error" breaking record.
- Two candidates for an optional dependency raise the error on first read.
- "Only one consumer" can be declared by the provider (a database with one schema) or by the consumer (Harbor's fixed Redis indexes). The build refuses a second consumer and names both.
- Namespace scope stops automatic binding from other namespaces. An explicit reference is allowed unless the provider carries a Secret, which cannot cross namespaces.
- A dependency can be used directly for ordering, as any resource can.

Needs your answer: 5.
Size: M. Question 5 decides whether it breaks existing cluster definitions (shown as an error).

### 8. A Secret that Kix does not build has no content Kix can use (theme 14)

When a Secret comes from outside the build, Kix knows its name and keys only. A change to its value restarts no pod and re-runs no bootstrap Job, and a wrong value length is found at runtime.

The design has three levels, as doc 167 mostly decided:
- A Secret Kix builds has a content hash, and everything follows from it.
- A Secret Kix only declares is checked at deploy for what was declared: that it exists, its keys, and stated value lengths. The key check at deploy already exists.
- A value that changes between deploys belongs to a controller in the cluster, because Kix is not running then. The secret helper wires the reloader for any secret dependency without a content hash, and warns when no reloader is present.

Settled without asking:
- No option holds a Secret's name. Alertmanager's and Grafana's pass-through credentials become secret dependencies. Evidence: `discussions/167_secrets_only_through_dependencies.md`, decision 1.
- The external secret store becomes a dependency. Evidence: doc 167, listed as not built.
- The helper returns the checksum and reloader wiring. Evidence: doc 167 rule S10, listed as not built.
- Rerun Jobs fold in the hash of what they require, so the checksum lists by hand go away.

Leaning (confirm or veto):
- SOPS Secrets are applied as `data`, so Kix owns the stored values and an edit made outside Kix shows as drift.
- A database password that changes outside Kix is applied by the database operator's own role management where it has one, not by a bootstrap Job.
- VolSync: accept the duplicated Secret for now. Composing one Secret from another is a job for the external-secrets package.
- The three database packages agree on one Secret name order at their next breaking release.

Needs your answer: nothing.
Size: M. Additive, apart from the pass-through options that become dependencies (shown as an error).

### 9. Cluster facts Kix cannot read (theme 13)

Kix does not know whether the cluster runs kube-proxy, which containerd version the nodes have, or which Kubernetes version it targets, because no cluster sets the version. Package version ranges therefore go unchecked.

The design: these are cluster facts stated in the definition and filled in by the flavour where it knows them. The build never reads the live cluster. The deploy compares stated facts with the live cluster, as it does for the Kubernetes version.

Settled without asking:
- The Kubernetes version stays optional. A package with a version range on a cluster with no version gets a warning that names the option. Evidence: `discussions/155_platform_versions_and_compatibility.md` principle 4, "unknown warns, false fails".
- The build does not read the live cluster. Evidence: doc 155 principle 5.
- Chart rendering uses the cluster's Kubernetes version, not Helm's default.
- kube-proxy presence and containerd version become cluster facts that flavours set.

Leaning (confirm or veto):
- A version range that applies to one option is stated in the build, where settings are available.
- Values read from a platform import carry its identity, so consumers are ordered after it.
- Storage providers publish supported access modes, and operator packages declare where their resources name a storage class.

Needs your answer: nothing.
Size: M. Additive. New warnings only.

### 10. Version selection reads `flake.nix` as text (theme 12)

To notice a hand-edited version tag, Kix scans `flake.nix` for strings that look like the library address. Each new file shape can produce a wrong answer, and two entries record such cases.

The design: Nix is the only reader of `flake.nix`. Kix asks Nix for the declared input where a moved tag matters, and caches the answer against the file's content. The lock file stays the source for choosing which Kix to run.

Settled without asking:
- Ask Nix (the entry's option a). Evidence: CLAUDE.md rules out heuristics, and the entry recommends it.
- The library check is keyed on the cluster and keeps no process-wide state.
- A flake that merges two Kix libraries into one output is refused.
- Every command that takes a cluster checks that the running Kix is the one that cluster pins.

Leaning (confirm or veto):
- An older Kix prints one warning naming each setting it skipped. Evidence: `CLAUDE.prose.md`, "for warnings, say what Kix skips".

Needs your answer: nothing.
Size: S to M. No cluster state change.

## Questions for Adam

**1. Does a plain `kix deploy` bring the whole cluster back to the build, or apply only what the build changed?**

Today `kix deploy` writes only objects whose build output changed. If someone deleted a Service or edited a field by hand, a deploy leaves it alone unless `--reconcile` is given. The operator heals such differences on every run. This is the real reason the operator cannot share the CLI's planner.

- (a) Deploy heals. The plan shows every difference between the cluster and the build, labelled as intended change or reverted drift, and the deploy applies all of it. The CLI and the operator then behave the same. It costs one read of every managed object per deploy, and a hand edit made during an incident is reverted by the next deploy, after the plan has shown it.
- (b) Deploy reports and does not heal. The plan and the deploy output list drift on untouched objects, and `--reconcile` heals. The operator keeps healing, so the two stay different on purpose.
- (c) Neither heals by default. The operator also only reports, and healing is always requested. One behaviour, but the operator stops being a reconciler.

I recommend (a). "Verifiable cluster artifact" means the cluster matches the build after a deploy, and it is the only option with one behaviour for both programs.

**2. Do Kix's per-deploy notes stay on every object, or move into the deployment record?**

After each apply, Kix makes a second write to the object to note which deploys reference it and a hash of what was applied. That second write races with operators that are saving status (Infisical lost its ready state). One operator copies the annotations into pods, so every deploy restarts all ClickHouse Keeper pods. The notes also change on objects the deploy did not otherwise touch.

- (a) Move both notes into the record. Objects carry only what the compiler wrote, in one apply. Every command reads one source. It costs a record that may need splitting across several objects on large clusters (the current index is capped at 150 KiB), and a release that reads both forms for six months.
- (b) Keep the notes on objects but stop rewriting unchanged ones. This removes the Keeper restarts. The race remains on every object that does change.
- (c) Keep today's design and exclude Kix's annotations in each affected operator's settings. This is a special case per operator.

I recommend (a). The roadmap already says to pick one place, and (a) also gives question 1 a single baseline.

**3. What form does the deploy lock take?**

Nothing stops two deploys of one cluster today. Kix has no namespace of its own, and its records are cluster-wide objects, one per deploy.

- (a) One Kix-owned object per Kix cluster that holds the lock with lease rules, the last writer, and the pointer to the current record. It is one new kind of object in cluster state, and it also fixes the "last finalize wins" and "which record is current" entries.
- (b) A standard Kubernetes Lease. It needs a namespace, so Kix must choose or create one on every cluster. The writer and the pointer would still need a home.
- (c) A lock field on the newest record. No new object, but the lock moves with every deploy and two starting deploys can each create a record.

I recommend (a).

**4. Do network intents leave package metadata?**

Twenty-three packages state intents in metadata, and the docs say they are keyed by workload, which the code ignores. The proposed design states them on the workload and derives outbound rules from the addresses a workload reads.

- (a) Remove the metadata form. The build refuses it with an error naming the new form. One way to say it, and no intent can land on the wrong pod. Every package with intents is rewritten, including packages outside this repository.
- (b) Keep both, as with the availability ceiling. Metadata means "every workload of this package", and the docs are corrected. No break, but the wide form stays easy to reach.
- (c) Keep metadata only and make the key select the workload. Small, but intents still cannot read settings, which is the entry hit six times.

I recommend (a). No network need is true of every workload in a package, so the package-wide form has no proper use.

**5. Can an instance's name satisfy a dependency?**

A dependency called `prometheus` is matched by any instance named `prometheus`, whatever its package. A Prometheus server named the obvious way captured dependencies meant for the operator. An instance named `storage` was mounted by Grafana as a volume.

- (a) Names never bind. Only declared aliases, roles, and explicit wiring do. When a same-named instance exists, the error says so and gives the alias line to add. Clusters that rely on names fail with a clear error once.
- (b) Names bind required dependencies only. Optional dependencies need an alias. This is a smaller break, with two rules to learn.
- (c) Names keep binding, and a dependency that states a contract rejects a provider that does not publish it. No break, but dependencies without a contract stay exposed.

I recommend (a). A name identifies an instance, and an alias declares what it provides.

## Belongs elsewhere

- `ingress-nginx-upstream-archived`: roadmap, service catalog. Mark the package deprecated in its metadata, since Gateway API is the stated direction.
- `no-kix-node-local-provisioner`: roadmap, service catalog. A missing package.
- `grafana-ha-not-wired`: roadmap, service catalog. A package feature with known parts.
- `external-dns-webhook-providers-need-sidecar`: roadmap, service catalog. A package feature.
- `expose-has-no-body-limit-or-fallback-backend`: design doc. It needs optional builders on the gateway contract.
- `cilium-enforcer-only-beside-another-cni`: design doc. Roles are fixed in metadata, which is the second shared concept above.
- `workload-placement-overlay-rebuilds-the-workload`: roadmap. Merge it into the existing "Uniform scheduling story" open question.
- `default-rules-absent-on-vm-only-clusters`: roadmap. Merge it into "Fold the VM packages into a monitoringProvider capability".
- `kind-cannot-test-multi-replica-defaults`: roadmap. Put it beside the Kubernetes window item that already asks for kind runs.
- `agents-in-parallel-worktrees-collide-on-one-machine`: neither. It is working practice, so it belongs in the package-authoring skill's kind steps.

## What I could not determine

- **How many cluster definitions rely on instance names for binding.** A build of the test clusters and the examples with name binding turned off would count them.
- **Whether the record can hold a per-object list on the largest real cluster.** The index cap and per-object cost are in `cli/kix-core/src/eval/package_index.rs`. A measurement on the biggest cluster would settle whether splitting is needed.
- **What a read of every managed object costs on each deploy.** Doc 157 left this open. Timing `kix status` on a large cluster gives the number.
- **Why ceded webhook rules still conflicted on stage2.** It could be the path parser that the duplicate-code theme already names, or the cede design itself. A reproduction on kind would tell.
- **Whether one field-manager name per Kix cluster turns a shared-object disagreement into a conflict.** It needs a two-cluster test on kind.
- **Whether CloudNativePG publishes any signal that ties "ready" to the current spec.** This needs a read of upstream's status code or an upstream issue.
- **How a package takes a list of secret dependencies whose length the user chooses.** Dependencies are named build arguments today, and I did not find a list form.
- **Whether the planner already re-applies objects whose applied hash no longer matches.** `discussions/122_runtime_content_drift.md` step 3 proposes it. The 2026-11-12 entry about deleted objects suggests it is not built.