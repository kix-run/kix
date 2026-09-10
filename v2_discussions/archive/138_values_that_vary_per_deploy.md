# 138: Values that vary per deploy, and the record of what was deployed

**Status:** Implemented, in #89 (`baec055`). Three of its decisions did not survive implementation review; §0 records them, and the body below is the reasoning as it stood, left unedited except for pointers back to §0.
**Related:** `117_self_service_platform_interface.md` (where configuration lives), `119_core_surface_audit.md` (boundary markers, refusal law 1), `120_compiler_theory_mapping.md` (§3.1 link-time typing, §3.9 no smart runtime), `129_scaling_axes_fleet_and_linking.md` (`kix promote`, the contract artifact), `archive/122_runtime_content_drift.md` (`applied-hash`)
**Source:** Adam, 2026-09-09, after `sha-REPLACE_ME` nearly took down Atlas on lab1 twice during the domain migration: "I like to think about the best practices here in terms of this replace me issue." Grounded by four parallel reviewers (Kix purist, online researcher, codebase, monorepo operations) and three critiqued designs.

## 0. What shipped, and what changed

The pin file and the deploy receipt shipped in #89. `ROADMAP.md` carries what
they are and where the code lives; `docs-legacy/HANDBOOK.md` §29 is the user
documentation. Three of this document's decisions were wrong, and the reasoning
for each is worth keeping because each mistake had a cause.

**The pin file is JSON, not Nix.** §5.1 and §9 said it had to be Nix, because
the evaluation cache fingerprints `.nix` files only, so a JSON pin file would
change a render without invalidating the cache. That was true when the sentence
was written and false by the time it was read: `d96297d` widened
`cli/kix/src/eval/cache.rs` to accept `.nix`, `.yaml`, `.yml` and `.json`. The
claim had been checked once, against a version of the file that no longer
existed, and then repeated in five places without being checked again.

With that gone the arguments run the other way. Reading a Nix file means
evaluating it, so a pull request that edited the pin file would be code
execution in CI. Writing one means escaping registry-supplied strings into a
programming language by hand, which is not a thing a bot should do every build.
And JSON is what the rest of Kix already writes, from `kix-packages.json` to
the SBOM. Doc 139 carries the correction forward.

**Pin keys are flat, and the tag names a stream.** §5.1 assumed one key per
image. A cluster can run several versions of the same image, so a key is
whatever string the operator wants: `atlas-server-prod`, `atlas-server-acme`,
`web-eu`. Kix never interprets it, which is what makes environments, tenants
and regions all work without a schema for the axis. The tag names a stream
(`main`) rather than a build (`sha-5d5dda2`), because a tag that changes every
build leaves the file with no stable key and puts CI back to editing the
cluster definition.

**There is no check over CI configuration.** §7.1 proposed a test asserting
that the pin file appears in no workflow's trigger `paths:`. That shipped as
431 lines of GitHub Actions YAML parsing and was deleted before merge. The
topology argument in §7.1 is right and its conclusion is the one that matters:
build, promote and deploy in one job. Once they are one job there is no
trigger edge to prove absent, so the check had nothing left to do. It also
would have been the only part of Kix that knew what GitHub Actions is, and it
could not see a `workflow_run` chain, so it proved less than it claimed.

Two things §7.1 got right and implementation kept: the deploy must happen in
the job that wrote the pin, and that job must confirm its push landed before
deploying. What it missed is that the loop closes on its own when the build
step is conditional on the source having changed. The bot's commit starts one
more run, nothing rebuilds, no digest moves, nothing commits. `[skip ci]` is
then an optimisation rather than a correctness requirement.

Still open, in `ROADMAP.md § Open design questions`: flipping `kix.image` from
advisory to mandatory, the rendered-manifest OCI bundle from §9, the Lithus
side of this document, and the `deploy-tiers.sh` comment from §7.

## 1. The problem

Kix has no sanctioned way for a value to differ between the committed cluster definition and what is actually deployed, and no durable record of what was deployed.

The image tag is one instance. The general form is **an input to compilation whose value is decided by an event outside the compilation unit**, such as a CI build or a promotion decision, for which Kix offers neither a channel nor a record.

Because the only lever that varies a value is editing the definition file, the monorepo's CI edits it in the working tree at deploy time and never commits. `client/lithus/clusters/lab1/kix/cluster.nix` therefore commits `serverImage.tag = "sha-REPLACE_ME"`.

That produces three defects with three different fixes, and the doc keeps them apart deliberately.

**The committed tree is not deployable.** A clean checkout renders a tag that does not exist. Three of the four routes that deploy lab1 (humans, agents, the compliance runbook) have no CI to lean on.

**The failure is silent through every layer.** `sha-REPLACE_ME` is a well-formed string, so eval passes, `security.noLatestTag` passes, `kix check` passes, and `kix deploy --dry-run` prints an ordinary "configured". The first signal is ImagePullBackOff, after the desired state in the cluster is already wrong.

**No durable record exists.** `kix.run/built-via` is a local `/nix/store` path on an ephemeral GCP builder, so for lab1 it has never resolved anywhere, and `kix compliance attest` stamps a git HEAD that does not contain the deployed content.

## 2. What actually varies per deploy

Deciding this narrows the design more than anything else in the doc.

**In scope, same mechanism.** Resolved references to first-party artifacts built from the same repository, meaning image tags and digests, and their promotion between environments. Doc 129 already assumes `kix promote staging prod` copies "pins" and never defines them.

**Out permanently: secrets.** sops already solves this correctly. The definition commits to the value by hash (`kix.run/sops-source` plus `kix.run/content-hash`), the CLI hydrates at apply, and plaintext never enters the artifact. Any new channel records values in cleartext on the Activation and in attestations, so a secret in that channel is an exfiltration path with no detection. Enforce it by closing the value type set rather than by convention.

**Out: canary weights and progressive rollout.** That is a value varying within one deploy intent over time, which is a rollout controller's job, not a compiler input.

**Out: environment-shaped differences** such as which packages exist, hostnames, and per-environment replica counts. Those vary per cluster, not per deploy, and belong in cluster definitions.

The corollary is a rule: **a per-deploy value may change a value inside an instance's configuration, never the resource set.**

## 3. Constraints any design must satisfy

These came out of the review with evidence attached, and several of them killed otherwise attractive proposals.

**A clean checkout at any commit must render exactly what is deployed**, with no flags, no environment variables, and no CI. A fix whose correct path exists only inside a workflow fixes one route in four.

**No deploy-time value channel.** `--set`, `--values`, `--var` and environment interpolation are excluded for a structural reason rather than taste. `detect_changes` indexes the previous build's manifests by Kubernetes identity and emits Skip whenever their `kix.run/identity-hash` equals the new build's (`cli/kix/src/cluster/apply.rs:138-170`), and that hash is the store hash of the manifest sealed *before* any CLI mutation. A value patched after eval never reaches the hash, so the second deploy of a changed value is a silent no-op.

**Resolution happens at compile or promotion time, never in `run_deploy` and never in an operator.** Doc 120 §3.9 already states this. A registry lookup on the apply path makes the artifact less predictive.

**An unresolved value must fail on the path CI actually walks.** lab1's CI runs none of the flake-level cluster checks, so a guard that only fires under `nix flake check` fires nowhere. Cluster-level error findings already fail `kix build` through `crossScorecardDiag` (`kix/lib/eval/cluster.nix:553`), and that is the hook.

**No lock without a key.** Every refusal must name an action the operator can take in the state that produced the refusal. This repository has shipped that mistake twice already, and three of the reviewed designs shipped it again.

**Fail closed on an unrecognised key.** A supply channel that warns on an unknown name and falls back to a committed default reproduces the sed-exits-zero hazard one level up.

**The record must be reconstructible from a machine that never built it.** No `/nix/store` path may be the authoritative value of any field. Coordinates must be fetchable names, meaning flake reference plus revision plus attribute. `built-via` survives only as a cache hint.

**The record must not carry manifests.** Annotations cap at 256 KiB, which is already load-bearing here, and `find_active` lists every Activation for the cluster on every deploy, rollback, gc, health and status call, so the record has to stay cheap to read.

**Both promotion routes must work: CI and a person.** Adam's answer to §7 was "ideally either". A design where the pin only exists as a side effect of a workflow fails the human route, which is the one used when something has gone wrong and CI is not the tool you reach for.

**stage1 and stage2 must need zero changes.** Every image in them comes from a kixpkgs package default already pinned by `flake.lock`. A design that taxes the two clusters that are already correct is the wrong design.

**One activation must carry mixed promotion models per instance.** `kix deploy lab1` has no per-package filter, so a CI-promoted package (atlas) and a hand-promoted one (`lithus-secret-operator`, pinned literally at `sha-0e8423e` in the same file) go out together.

**No CI push to a branch that then re-triggers CI.** `cluster.nix` is already in `atlas.yaml`'s push `paths:`, so an unexcluded pin file beside it is a self-feeding promotion loop. §7.1 gives the cut.

## 4. The asymmetry that explains everything

The same `cluster.nix` commits `lithus-secret-operator`'s tag literally, with a comment defending the choice, and sentinels Atlas's two tags.

The difference is not principle, it is who decides the value. The operator's tag is bumped by a human as a deliberate act, so it is committed. Atlas's is decided by a CI build that happens after the commit exists, so there is nowhere to put it.

That is the whole problem in one file, and it says the fix is not "stop using placeholders". It is **give the post-commit decision somewhere to land**.

## 5. Recommendation

Compose the source-side fix with the first tier of the record-side fix. They are separable and should ship as separate changes with different urgencies.

### 5.1 Source side: committed pins

A committed, CD-owned `pins.nix` per cluster, sibling of `cluster.nix`, holding `{ repository, tag, digest, sourceRev, promotedBy, resolvedAt }` per first-party image key.

Nix rather than JSON, for a verified reason rather than taste: `compute_source_fingerprint` walks `.nix` files only, so a JSON pin file would leave `kix build`, `check` and `inspect` serving a stale render after a promotion. *(Wrong, and the file shipped as JSON. See §0.)*

`kix pin` is the promotion verb. `kix pin <cluster> <key> --tag <t>` queries the registry, refuses a tag that does not exist, resolves the digest, and rewrites the file. It takes an explicit `--pins-file <path>` and needs no evaluation to find its target, plus `--init` for the bootstrap case. Without that, the flagship error message ("run `kix pin ...`") is a refusal whose remedy is unrunnable in exactly the state that produced it.

**What actually closes the placeholder class is not eval.** Nix evaluation is pure and can never check that a digest has a referent, so a hand-written well-formed fake digest passes every eval-time rule. The closing move is `kix pin --check` as a required status check on every PR touching a pins file, verifying **by digest rather than by tag**. A registry retention job that deletes an old tag whose digest still runs must be a warning, not a red PR with no remedy.

The doc should say plainly that this narrows the class rather than eliminating it.

### 5.2 Record side: the deploy receipt

Move the provenance `kix compliance attest` already computes into the Activation record. `build_attestation` in `cli/kix-cli/src/commands/compliance/attest.rs` (`build_attestation`, line 40) already assembles the flake reference, git HEAD, a BLAKE3 of `flake.lock`, every input's revision and narHash, and the kix and Nix versions, and then prints it to stdout and discards it.

Writing that into the `spec_patch` that already stamps `deployed-at` and `previous` is plumbing rather than a new mechanism, and it inverts the dependency: `attest` becomes "read the record", so a deploy can be attested from a machine that never built it.

Explicitly **not** in this tier: manifests, redacted or otherwise.

## 6. Rejected, and why

**`--set` / `--values` / `--var` / environment interpolation.** Structurally a no-op rather than merely untidy, per the identity-hash argument in §3. It also makes `kix compliance attest` emit a well-formed false statement, and a false attestation is worse than none.

**Threading `self.shortRev` into cluster definitions.** Genuinely tempting: it is about five lines in `mkFlake.nix`, which today passes cluster functions only `kix` and `packages`, and it deletes the sed today, because the image is built from the same commit as `cluster.nix`, so the tag is a pure function of the compilation unit's own locked identity. Rejected for this purpose because it yields a tag and not a digest, so the resolution gap stays open; because every monorepo commit then changes every lab1 image reference, making every merge a full redeploy; and because `git show <sha>:cluster.nix` stops answering the question, since the answer depends on which revision it was evaluated at. Its legitimate use is as an *input* to promotion.

**A separate CD-owned branch, the rendered-manifests or Source Hydrator pattern.** The deployable tree stops being the tree anyone reviews, main still cannot answer what was deployed, and you own merge-back forever. Argo CD pays that cost because its dry source is an unpredictable template engine. Kix's eval is hermetic, so a protected pin file buys the same audit property at one line per image.

**Manifests in the record, in annotations or inline in spec.** Size limits, and `find_active` lists every Activation on every command.

**`kix deploy --from-activation`.** It turns the receipt into a source, so a cluster could be redeployed indefinitely from a record whose preimage exists nowhere. That does not fix the placeholder problem, it makes it permanent.

**Tag to digest resolution inside `kix deploy` or an operator.** A non-goal per doc 120 §3.9. A `digest: null` that tells the truth is worth more than a value obtained by a network call at apply time.

**A placeholder denylist (`REPLACE_ME|CHANGEME|TODO`) as the primary fix.** A predicate over tag spelling is the shape being condemned in `noLatestTag`, since `sha-typo12` passes it. Keep it only as a ratchet, per §8.

## 7. The decision: continuous deployment, and both routes work

Adam, 2026-09-09: "ideally either to be honest ... we have a preference for continuous deployment."

The apparent conflict that raised this question dissolves on inspection. `.github/lib/deploy-tiers.sh` says tier-3 production clusters are manual-dispatch only, but that file was written on 2026-07-09 as part of the Spindle control-plane work, and its subject is lab0 single-node services. It says so itself: "Tiers 2 and 3 have no automation consuming a node list yet, so they live as documentation above rather than as variables below." It listed the Kubernetes clusters for completeness, not as a policy anyone had applied to them. Two weeks later, `2b0b4f113` flipped lab1 to deploy on every push to main and called it the house CD pattern. That was the deliberate decision, and it stands.

So the design does not get to shed half its machinery. §7.1 is the plan rather than a contingency.

**"Either" is a real constraint, and a good one.** The promotion step has to be a thing a person can run as easily as CI can. That rules out any design where the pin only exists as a side effect of a workflow, and it is why `kix pin` takes an explicit `--pins-file` and needs no evaluation to find its target. A human running it on a laptop and a CI job running it on a throwaway runner must produce the same commit. Test both paths, not just the CI one, because the CI path is the one that gets exercised daily and the human path is the one that gets used at three in the morning.

**A side effect worth fixing separately.** `deploy-tiers.sh` now says tier 3 is "never auto-deploy" while lab1 auto-deploys. That comment is misleading to the next reader, and it is what sent this doc down a blind alley for half a day. Correct it to describe what we actually do.

### 7.1 How the trigger loop is cut

With §7 settled on continuous deployment, this is load-bearing rather than contingent.

**The pin file appears in no workflow's trigger `paths:`, and a test asserts that.** *(The test was built and then deleted; the one-job conclusion below is what shipped. See §0.)* This is the whole cut. A pin commit must trigger nothing, or the loop is structural: pin commit, build, new short sha, pin again. The test matters more than the exclusion, because the exclusion is one line that a later well-meaning change reinstates. Assert it in CI over every workflow file, not in a comment.

**The deploy therefore happens in the same job that wrote the pin.** Once the pin commit triggers nothing, nothing else can start the deploy. Build, push the images, run `kix pin`, commit, push, then deploy, in one job. This is lab0's shape, which is uncomfortable, and it is the honest consequence of auto-on-merge rather than a flaw in the proposal.

**After pushing the pin, fetch and assert that `origin/main` is the pin commit.** If someone merged while the job ran, main has moved past the tree about to be deployed, and deploying it would revert their change. Refuse instead. The workflow already serialises applies with a concurrency group, so this should be rare, and a refusal costs a re-run rather than an incident.

**The cost, stated plainly.** This is the lab0 pin-drift hazard, accepted rather than avoided. The difference is that lab0 let the pin and the deployed state drift apart silently, and this refuses when they disagree. That is a better failure, not an absent one.

**If any of that cannot hold, the answer is manual dispatch, not a cleverer topology.** A promotion path that needs a human gate between pinning and deploying does not fit in one job, and trying to make it fit reintroduces the loop through another door.

## 8. Immediate mitigation

Three things, none of which commits to any long-term design.

**Make the committed tree deployable, today.** Replace both `sha-REPLACE_ME` values in `cluster.nix:339-340` with the tag actually running, and commit. The CI sed is anchored on the field name rather than the sentinel, so it keeps working unchanged and its existing post-sed grep guard still asserts the new sha landed. This converts "a clean checkout breaks production" into "a clean checkout deploys a possibly stale but real image".

**Ship a ratchet against reintroduction.** Add `security.noUnresolvedPlaceholder` beside `noLatestTag`, reusing the same container extraction, failing any image reference matching `REPLACE_ME|CHANGEME|PLACEHOLDER|TODO|XXX|\$\{`. Warning by default, error under lab1's flavor, which already promotes `noLatestTag` to error. It fires on the `kix build` path through `crossScorecardDiag`, which matters because lab1's CI runs none of the flake-level checks. Its only job is to make the sentinel unwriteable again.

**Stop attesting a commit that does not contain the deployed content.** `git_commit` in `cli/kix-cli/src/commands/compliance/shared.rs:83-100` records `git rev-parse HEAD` with no dirty detection. Add `git status --porcelain`, record the dirty flag and Nix's own `dirtyRev` spelling, and warn above the deploy confirmation.

Not in the mitigation: hardening the sed, which is already done, and rewriting the deploy runbook, which should keep its "commit the pin" step until a source-side fix lands.

## 9. The questions, answered

The first draft left six questions open. Five now have answers, from our own code and from prior art. The sixth was built on a false premise. Sources are in §11.

**Is the receipt a `spec` field or a `status` field? Status.** The Activation CRD already declares `subresources: {status: {}}`, and the CLI already writes status through `patch_status` in four places in `cli/kix/src/cluster/activation.rs`. A status subresource is not touched by applying the main resource, which removes the failure the question was really about: a rollback re-applying the Activation manifest cannot erase the receipt. Kubernetes convention agrees. Users get write access to spec and read-only status; controllers get the reverse, and the receipt is an observation of what happened rather than a statement of intent. The machinery exists, so this costs nothing.

**Does the receipt duplicate the PackageInstance records? No.** A PackageInstance carries `{instanceName, lifecycle, namespaceName, version}`, and `version` is the package version, `0.1.0` on lab1 today. It holds no image reference. There is no overlap to reconcile, so the receipt can be self-contained without a second source of truth.

**Is `pins.nix` doc 129's "pins"? No, but they are the same family.** Doc 129 uses "pin" for a pinned cross-cluster contract, and names **pin coherence** as the fleet-level computation over them. That is a different object: which version of another cluster's exports you depend on, not which image you run. They should share the shape of a resolved reference recorded in the repository, and they should not be merged. Retrofitting one onto the other would give us a format that serves neither.

**Is `kix.image` mandatory or advisory? Advisory first, then mandatory, with a named flip condition.** No package in `kix/packages` carries a digest field today and there is no shared image-option helper, so a mandatory rule at error severity breaks every cluster including `ludo/#cluster-ludo-kind`, the canonical smoke test. The policy-engine world solved exactly this: Kyverno ships `validationFailureAction: Audit` and Gatekeeper `enforcementAction: warn` precisely so a new constraint can be rolled out across existing workloads without a flag day, and the documented practice is to audit, work the backlog down, then enforce. Copy it: land `kix.image` as a convention, add the rule at info severity scoped to instances whose package declares a digest slot, and flip to error when coverage reaches every package rather than on a date. Write the flip condition into `ROADMAP.md`, because an advisory rule with no flip condition never flips.

**Does rollback from any machine stay out of scope? Split the question, because the two halves have different answers.** Audit and diff from any machine is achievable. Push the rendered manifests to the registry as an OCI artifact and reference it by digest from the receipt. Flux does this already, under the name gitless GitOps, for exactly our case: the repository does not contain the final manifests because a generator produces them. It puts the bundle where the images already live, so it inherits their credentials and retention, and it sidesteps every size limit in §3. **Rollback by replay does not follow, and we should stop implying it might.** Built manifests carry secret values inline. `immich-db-bootstrap-password` in the example cluster renders `stringData.password` with a literal in it. So an unredacted bundle is a credential archive in the registry, which is Helm's documented failure moved to a worse-read place, and a redacted bundle cannot be applied, because a Secret with its body removed applies cleanly and fails at authentication. Rollback by replay needs the plaintext, which needs sops, which needs the source. So: **build the bundle for audit and diff, and keep rollback tied to the source.**

**Does anything else read a non-`.nix` file into eval? The premise was wrong, so the worry does not arise.** `compute_source_fingerprint` walks `.nix` files only, but `compute_key_with_source` hashes the contents of `flake.lock` directly into the cache key alongside that fingerprint (`cli/kix/src/eval/cache.rs:171`). A pin bump therefore invalidates correctly, and there is no latent stale-render bug. The reason to prefer `pins.nix` over `pins.json` survives unchanged and is now better stated: JSON is in neither the fingerprint nor the key, so a JSON pin file would be the one input that changes a render without invalidating the cache. *(False since `d96297d`, which widened the fingerprint to `.json`. See §0.)*

## 10. The risk to watch

The recommended design introduces a **new silent failure that is better disguised than the sentinel**. If the promotion step does not run, because a paths filter stopped matching or a job was skipped, the deploy succeeds, every rule passes, `--dry-run` says configured, and the Activation records honest provenance, all while the cluster runs old code.

Today that failure detonates visibly at ImagePullBackOff.

Only asserting freshness against `sourceRev` closes it, and nothing in the original proposal read `sourceRev` at all. Any implementation has to carry that assertion or it trades a loud failure for a quiet one.

## 11. Prior art, and where the evidence is thin

Researched 2026-09-09. Every claim below has a source, and the two weak spots are named at the end rather than smoothed over.

**Everyone who solved this chose to persist the value.** Flux marks the field in the file and rewrites it with an ordinary Git commit, using a machine-owned marker rather than a text substitution: `image: ghcr.io/org/app:4.0.6 # {"$imagepolicy": "flux-system:my-policy"}`. The committed value is always real ([Flux image update](https://fluxcd.io/flux/guides/image-update/)). Kargo promotes an immutable object, Freight, naming resolved digests, and rollback restores an exact prior Freight ([Kargo core concepts](https://docs.kargo.io/user-guide/core-concepts)). Argo CD Image Updater offers a cluster-only write-back and warns against it in its own docs: "If you delete the Application resource from the cluster and re-create it, changes made by Image Updater will be gone" ([update methods](https://argocd-image-updater.readthedocs.io/en/stable/basics/update-methods/)). That last one is a direct warning against passing the value at deploy time and recording it only in the cluster.

**Build systems already split values on our axis.** Bazel divides stamps into stable and volatile on exactly the question of whether the value changes the artifact; stable keys invalidate actions while Bazel "pretends that the volatile file never changes" ([workspace status](https://bazel.build/docs/user-manual#workspace-status)). An image tag changes the rendered manifest, so it is a stable stamp, and there is no design where Kix injects one without changing the artifact. `rules_oci` goes further and refuses to stamp image content at all, allowing stamps only on labels and annotations ([rules_oci#49](https://github.com/bazel-contrib/rules_oci/issues/49)). That is the two-tier rule this doc adopts: values that change what runs go through evaluation, values that describe the build go on the record.

**Gradle is the closest mature analogue.** Source declares a range and a committed lock file records the resolution, so "the release tag will contain the lock states, allowing that build to be fully reproducible" ([dependency locking](https://docs.gradle.org/current/userguide/dependency_locking.html)). That is `pins.nix` in another ecosystem. Terraform makes the complementary point: variables stay ephemeral and state stores the resolved concrete values ([state tutorial](https://developer.hashicorp.com/terraform/tutorials/state/state-cli)), which supports the record side and warns that a record then holds everything.

**Nix refuses rather than recording a lie.** A flake with a dirty worktree gets no revision at all, and the common idiom throws instead of guessing ([nix#6034](https://github.com/NixOS/nix/issues/6034)). Our CI deliberately dirties the tree and stages the edit so the flake picks it up, which means `self.rev` is unavailable at precisely the moment we would want to stamp honest provenance.

**A record must hold both the request and the resolution.** SLSA separates `externalParameters`, what was asked for, from `resolvedDependencies`, what it resolved to ([build provenance](https://slsa.dev/spec/v1.2/build-provenance)). Argo CD shows the failure when you record only the request: for multi-source Applications the status "doesn't contain the resolved git revision in the status field, only the targetRevision", so users cannot tell what was deployed ([argo-cd#13859](https://github.com/argoproj/argo-cd/issues/13859)). An Activation recording `tag: sha-abc1234` and not the digest repeats it.

**Pointer-only records fail the way ours already does.** Argo CD's history stores pointers, and users hit "Unable to rollback application ... repository not accessible" when the repository is down ([argo-cd#21480](https://github.com/argoproj/argo-cd/issues/21480)). That is `built-via` exactly, lived through by the largest GitOps tool. Flux stores less again: `.status.inventory` is object references for drift detection and garbage collection, not for reconstructing a deploy ([kustomize controller](https://fluxcd.io/flux/components/kustomize/kustomizations/)). Kix sits at the Flux end today.

**Storing manifests has three costs, and together they decide §5.2.** Helm stores full rendered manifests in cluster Secrets and hits a hard 1 MiB object limit ([the 1 MB release limit](https://jkroepke.de/2026/02/handling-large-files-and-crds-in-helm-and-the-1mb-release-limit/)). Those records also become a credential archive, since anyone who can read them "can retrieve and decode the entire release history, including previous values of rotated credentials" ([secrets in Helm charts](https://ghostcred.io/blog/secrets-in-helm-charts-kubernetes-credential-exposure)). And the annotation route is worse still: `kubectl.kubernetes.io/last-applied-configuration` fails at the 262144-byte annotation limit ([kubectl#712](https://github.com/kubernetes/kubectl/issues/712)), which is where `built-via` lives today. Hence provenance, not manifests.

**Tags are insufficient even when correct.** A moving tag is a time-of-check to time-of-use problem: "The image that is verified during the CI/CD pipeline or the Kubernetes admission phase differs from the image that is deployed in the cluster, bypassing image scanning security checks" ([Sysdig](https://www.sysdig.com/blog/toctou-tag-mutability)). Reading the digest back from pods does not rescue it, because `status.containerStatuses[].imageID` differs by runtime and can report the wrong digest on multi-architecture images ([kubernetes#115199](https://github.com/kubernetes/kubernetes/issues/115199)). The record must be written at deploy time by whatever made the decision.

**The text substitution has a known failure mode, already guarded here.** `sed` exits 0 when it matches nothing, so `set -e` does not protect you: "The retry runs sed against a file where the source pattern no longer exists, sed shrugs and exits 0 ... Silent no-op. The pipeline goes green" ([sed in CI/CD](https://karandeepsingh.ca/posts/sed-in-ci-cd-pipelines/)). `atlas.yaml` already asserts with `grep` after substituting, so this specific hazard is closed. The live defect is the uncommitted tree, not the substitution.

**The principles are citable rather than invented.** OpenGitOps requires desired state to be "expressed declaratively" and stored "in a way that enforces immutability, versioning and retains a complete version history" ([OpenGitOps](https://opengitops.dev/)). A tree rendering `sha-REPLACE_ME` expresses a desired state that is valid and false. Argo CD's anti-pattern 14 puts it plainly: the desired state "is only true if you store EVERYTHING that the application needs in Git" ([30 Argo CD anti-patterns](https://octopus.com/blog/30-argo-cd-antipatterns-for-gitops)). One practitioner framing is worth borrowing for the record's name: "main always equals production", and "the merge is the receipt, not the trigger" ([you're not doing GitOps](https://htek.dev/articles/youre-not-doing-gitops-cicd-with-extra-steps)). Read that way, lab1 lets main lie in a fixed obvious way and lab0 let it lie in a racing subtle one. Same defect.

**Thin spot one: nobody has named this.** Repeated searches for an established name covering "a committed placeholder that renders a valid but wrong manifest" found nothing. The nearest named things are Argo CD anti-patterns 9, 12 and 14 and the generic idea of a magic string. Do not write as if the industry has a term for it.

**Thin spot two: there is no incident record against flag-supplied versions.** No substantial body of post-mortems exists for outages caused by `helm --set image.tag`. The closest public case is Berkeley DataHub in 2017, where a hub failed to start because "helm's config did not match the hub's image" ([incident](https://docs.datahub.berkeley.edu/incidents/2017-03-06-helm-config-image-mismatch.html)). So the case against a flag rests on our own identity-hash argument in §3, on auditability, and on the fact that Kargo, Flux and Argo CD independently chose to persist the value. It does not rest on a public outage record, and the doc should not imply otherwise.

**Sources for §9.** The spec-versus-status split is the Kubernetes API convention: users get write access to spec and read-only status, controllers the reverse ([API conventions](https://github.com/kubernetes/community/blob/main/contributors/devel/sig-architecture/api-conventions.md)), and Server-Side Apply fully supports status as a subresource, which is why an apply of the main resource leaves it alone ([Server-Side Apply](https://www.kubernetes.io/docs/reference/using-api/server-side-apply/)). The audit-then-enforce rollout for `kix.image` is Kyverno's `validationFailureAction: Audit` and Gatekeeper's `enforcementAction: warn`, both documented as the way to introduce a constraint across existing workloads without a flag day ([Kyverno Gatekeeper migration guide](https://kyverno.io/docs/guides/gatekeeper/)). The bundle-as-OCI-artifact answer is Flux's, which pushes rendered manifests to a registry precisely when "the Git repository doesn't contain the final Kubernetes manifests" because a generator produced them ([Flux OCI cheatsheet](https://fluxcd.io/flux/cheatsheets/oci-artifacts/)); the reason we can take the mechanism and not the replay is the Helm credential-archive finding already cited above.

