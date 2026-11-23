# 172c: Bump to the newest version that can be installed

**Status:** Implemented. Design B (§4.2) was built, with the differences in §5.
**Related:** `172_package_version_upkeep.md`, `172b_bump_workflow_operations.md` (§2.3 rule 3, which this doc completes), `159_patched_images_pipeline.md`, `170_instance_version_from_main_image.md`

All file and line references in §2 and §6 are to main at `a537fa1be`,
before the change. Run and pull request numbers are from `kix-run/kix`.

## 1. Summary

Detection reads upstream's release list and starts a bump for the newest
tag. It never asks a registry anything. The agent is then told to confirm
the images exist, and may pick another version. So two components own the
decision "which version do we move to", and the first one decides without
the fact that matters.

The observed result is a run that ends green with the outcome `not-ready`
and opens nothing. On 23 Nov 2026 ClickHouse stayed at 26.8.40.7 although
26.8.44.3 was released and published, because detection offered only
26.8.45.6, whose image was 19 minutes from existing.

The proposal: detection builds an ordered list of candidate releases from
the release feed, tests each against the registry with one shared readiness
check, and starts the bump for the newest candidate that passes. The agent
stops choosing versions. Detection then costs no agent run, so it can run
daily or hourly, and a release whose image is late is picked up on the first
run after the image appears, with no stored state and no timer.

## 2. What happens today

### 2.1 Stages, decisions, and the facts each uses

| Stage | Decides | Facts it uses | Where |
|---|---|---|---|
| Detect, Mondays 06:00 UTC or by hand | The target version, and whether to start a run | Pinned `meta.version`; upstream GitHub releases that are neither draft nor pre-release, or git tags; the `tags`, `track`, and `skip` settings | `bump-detect.yml:15`; `detect.py:84-129`, `:215` |
| Detect, de-duplication | Whether this target was already handled | `bump-target` markers on the app's issues and pull requests in any state; `bump-dirs` on open ones; earlier runs by title | `detect.py:155-172`, `:217-230` |
| Detect, dispatch | Which bumps start | Step size, then name; at most 5 | `detect.py:238-241`; `bump-detect.yml:43` |
| Agent | Whether the target is usable, which version to reach, and the outcome word | Whatever it looks up, by a method it chooses | `brief.md:7-8`, `:55-63` |
| Verify, on amd64 | Whether an `upgraded` result is complete | `check-bump.sh`; then for each default image option, whether the pinned reference has a `linux/amd64` build | `bump-agent.yml:349-364`; `check-images.py:62-88` |
| Publish | Pull request, draft, or issue | The outcome word and the commit count | `bump-agent.yml:406-478` |

`newest()` returns one value, `max(found)` (`detect.py:129`). Nothing in
`detect.py` contacts a registry. The only mechanical registry check is the
last step of the pipeline, it runs only for `upgraded`
(`bump-agent.yml:361`), and it checks one platform.

Doc 172b designed this differently. Its rule 3 says "The image exists. The
script looks the target's tag up in the registry and records the digest. A
tag with no image is not a target yet" (`172b:146-149`). The built
`detect.py` has rules 1, 2, and 4, and no rule 3.

### 2.2 Case 1: the newest release has no image yet

Detection starts the run. The agent checks the registry, writes `not-ready`,
and stops. The collect step prints a notice (`bump-agent.yml:283-285`), and
verify and publish are skipped (`bump-agent.yml:303-306`). The run is green
and leaves no issue, pull request, or marker.

| Run | Target | Model, cost, time | Result |
|---|---|---|---|
| 44508242677, 19 Nov | echo-server 1.30.7 | Haiku, $0.04, 10 min | `held`, draft PR #259. The `not-ready` outcome did not exist yet (added by #261) |
| 44569700806, 19 Nov | echo-server 1.30.7 | Haiku, $0.03, 2 min | `not-ready` |
| 45218840423, 23 Nov | echo-server 1.30.8 | Haiku, $0.02, 2 min | `not-ready` |
| 45218828339, 23 Nov | clickhouse 26.8.45.6 | Opus, $0.39, 2 min | `not-ready` |

So the report that started this doc is right about the waste and wrong
about the failure: the run does not fail. A failure is possible on another path that
has not occurred yet (§6.3).

The brief says "the weekly check starts this bump again" (`brief.md:60`).
In fact every detect run does, because a green run is in neither state set
that `detect.py:225-230` tests. Detect run 45219968501 started echo-server
1.30.8 and clickhouse 26.8.45.6 again (runs 45222774163 and 45222767945)
twenty minutes after both had ended `not-ready`. Someone cancelled them.

### 2.3 Case 2: the newest has no image, an earlier one does

The second report is right in effect. The mechanism is a green run that
bumps nothing.

Run 45218828339: the package pinned 26.8.40.7. Upstream had released
26.8.41.14, 26.8.42.13, 26.8.43.13, 26.8.44.3, and 26.8.45.6 since
(GitHub releases, read 23 Nov). The 26.8.44.3 images had been on Docker Hub
since 22 Nov 16:07 UTC, for both architectures. Detection offered 26.8.45.6,
published on GitHub at 16:21 UTC. The agent looked at 16:40, found no
image, and reported `not-ready`. Its report names 26.8.44.3 as the newest
tag on Docker Hub and does not consider moving to it. The 26.8.45.6 image
appeared at 17:23.

The brief does allow a fallback: "If it is broken, take the newest release
that is not" (`brief.md:7`). But `not-ready` is defined about the target
alone (`brief.md:60`), so the two instructions point different ways for a
missing image, and the agent picks one. The echo-server agent in run
45218840423 did look for an earlier version and found none, since neither
1.30.7 nor 1.30.8 has an image (still true at the time of writing, five
days after 1.30.7, which fixes nine CVEs).

Had an agent fallen back, the result would have been wrong in a different
way. See §6.2.

## 3. Root cause

**"Released upstream" is treated as "can be installed".** A release
becomes installable when everything the package pins from it is published:
each image, for each platform Kix needs, and the chart where there is one.
Upstreams publish these minutes to days after the tag. ClickHouse takes
about an hour (releases at 15:10 and 16:21 UTC, images at 16:07 and 17:23).
The `nginx-unprivileged` image took five days for 1.30.6, by the agent's
reading of Docker Hub in run 45218840423.

**Two components own one decision.** Detection picks the target. The agent
may replace it (`brief.md:7-8`). The branch name, run title, pull request
title, `bump-target` marker, and concurrency group are all fixed from
detection's answer before the agent starts (`bump-agent.yml:3`, `:67`,
`:80`, `:428`, `:447`). An agent that reaches another version cannot say so
in any of them.

**The concept that is missing is the candidate.** Detection has a list of
tags and collapses it to one before any test that could reject a tag. With
an ordered list of candidates and a test applied to each, "the newest is not
ready" and "take the next one" are the same loop.

**Readiness has no single definition.** The agents in the four runs above
used `docker buildx imagetools`, the Docker Hub tags API, the registry v2
API, and `docker manifest inspect`, in different mixes. One report says the
arm64 build was left unverified. `check-images.py` is a fourth definition
(amd64 only, default options only).

### 3.1 Which source is the truth for candidates

The release feed and the registry answer different questions, and the
design needs both.

- The feed says what a release is: its version, its order, whether it is
  a pre-release, and where its notes are. Only the feed can say that
  `26.8.45.6` is an LTS release and `26.10.11.12` is another line.
- The registry says whether a release can be pulled. Its tag list cannot
  define candidates: it holds release candidates, nightly builds,
  per-architecture tags, and tags that were pushed again (housekeeping
  entries of 17 and 18 Nov on echo-server, cnpg-cluster, keycloak, and
  clickhouse).

Candidates come from the feed. The registry filters them. For five sources
the feed and the image belong to different publishers (echo-server,
cnpg-cluster-postgres, stackgres-database-postgres, cnpg-pooler,
rabbitmq-cluster), so a lag between them is the normal state there.

### 3.2 What a release needs, by package shape

Read from `kix/packages/default-images.nix`, evaluated on this checkout
(62 sources):

| Shape | Count | What must exist |
|---|---|---|
| One image whose tag names the version | about 35 | That tag, on the required platforms |
| Several images that share the version (kubevirt 13, mayastor 16, harbor 7) | about 15 | Every one. Upstreams publish these over minutes, so a partial set is a real state |
| Helper images on their own version line (kubectl, busybox, `k8s-sidecar`, `redis_exporter`) | inside 24 multi-repository sources | Nothing, for this decision. The upstream version does not determine them |
| Helm chart (cilium, smartctl-exporter, via `scope.helm.fetchHelmChart`) | 2 | The chart version in the chart repository. Its images come from chart values |
| Manifests or CRDs only (gateway-api) | 1 | The tag itself |
| Operator and operand | several pairs | Each is its own source already. Whether the pinned operator supports a new operand version is a compatibility question for the agent |

The library already owns the link between an image tag and a version:
`versions.ofTag` (`kix/lib/core/version.nix:74`), which `kix.image.version`
uses (`kix/lib/vocab/compose.nix:69-74`). An image follows the release when
`ofTag tag` equals `meta.version`. That is a computed fact about the
package, so detection does not need a list of images in `sources.toml`.

## 4. Candidate designs

### 4.1 Design A: check the registry in detection

`newest()` returns the candidates in descending order. Detection walks
them and takes the first whose images exist, by replacing the pinned
version with the candidate's inside each default image tag that contains it
and asking the registry with `crane`.

- **Changes:** `detect.py` (about 60 lines), `bump-detect.yml` (evaluate
  `default-images.nix`, add `crane`), the run summary (a "released, image
  not published" list).
- **Cost:** a day. One registry request per image per behind package.
- **What remains:** the tag rewrite is a second copy of the tag grammar,
  in Python, and it is a text substitution. The agent can still change the
  version (§6.2). Chart packages are unchecked. `check-images.py` stays a
  separate definition. `not-ready` stays as an agent outcome with no
  memory.

### 4.2 Design B: detection owns the target, through one readiness check

1. **A library function gives the images of a release.**
   `default-images.nix` gains a second output: for a package and a version,
   the image references that follow the release, with the version replaced.
   The replacement is a new function beside `versions.ofTag`, using the same
   grammar, so the two directions cannot drift.
2. **One script, `readiness.py`, defines "can be installed".** Given image
   references and chart coordinates, it reports for each whether it exists
   and on which platforms. Required platforms are `linux/amd64` (most
   clusters) and `linux/arm64` (the agent's test machine). It replaces
   `check-images.py`. Detection calls it on candidates. Verify calls it on
   what the agent pinned.
3. **Detection picks the newest ready candidate.** The summary lists newer
   candidates that are not ready, with what is missing and the release
   date. The dispatch carries that list, so the pull request can say
   "2.0.1 is released and its arm64 image is not published".
4. **The agent stops choosing versions.** `brief.md:7` becomes: the
   workflow confirmed the images exist; if the release is broken or
   withdrawn, the outcome is `held`. `brief.md:8` goes (see stepping
   below). Verify adds one check: `meta.version` at the head commit equals
   the target.
5. **`not-ready` changes meaning.** Detection handles the ordinary case
   without an agent. If an agent still finds something missing, the
   readiness check has a gap for that package. The run opens an issue with
   the `bump-target` marker, so the gap gets fixed and the bump does not
   start again every run.
6. **A `step` setting in `sources.toml`,** beside `track`. With
   `step = "minor"`, detection targets the newest ready patch of the pinned
   minor, and after that the newest ready patch of the next minor. KubeVirt
   documents this rule (PR #270's report). A person adds the setting with a
   comment when upstream documents the rule. Doc 172 §4.5 proposes
   package-declared upgrade rules. When those exist, detection reads the
   step from them and the setting goes.
7. **Detection runs daily.** It starts no agent for a release that is not
   ready, so a frequent run is cheap, and a late image is picked up within
   a day with nothing remembered between runs.

- **Changes:** `detect.py`, new `readiness.py`, delete `check-images.py`,
  `brief.md`, `sources.toml` (`step`, and chart coordinates for the two
  chart packages), `bump-detect.yml`, `bump-agent.yml` (verify step,
  `not-ready` branch), `kix/lib/core/version.nix`,
  `kix/packages/default-images.nix`, the package-authoring skill's bump
  section, `kix/lib/architecture.md` if the new function warrants it.
- **Cost:** about a week with tests.
- **What remains:** helper images are still chosen by the agent and checked
  only in verify. Images that come from chart values are still invisible
  (housekeeping, 19 Nov). A release that names its own companion version,
  as Envoy Gateway does for Envoy, needs the agent. `sources.toml` and the
  package still both describe the upstream.

### 4.3 Design C: the release is data, and a script pins it

Design B plus three things.

1. **Each package keeps its release in `release.nix`,** as
   `immich/release.nix` does today: the version, each image's repository
   and tag shape, and the digests. `meta.upstream` (doc 172b §2.1) replaces
   `sources.toml`.
2. **A resolver turns a candidate into a resolved release:** every image's
   index digest and platforms, and the chart's hash. Readiness is "the
   resolver succeeds". The workflow writes the resolved release into
   `release.nix` as the first commit, before the agent starts. The agent
   begins on a tree that already pins the target and does the work that
   needs judgement: upstream changes, the edit, the tests, the records.
3. **The image list comes from a build.** The resolver builds the package's
   test cluster at the candidate and reads every image from the built
   manifests, which Kix already records as `kix-image-sources.json`
   (`compose.nix:55-58`). Chart and operator images are then covered.

- **Changes:** all of `.github/bump/`, every package folder, the
  package-authoring and package-review skills, the package reference docs.
- **Cost:** two to three weeks, most of it the per-package move.
- **Gains beyond this problem:** agents stop looking up digests, which the
  housekeeping entries of 17 and 18 Nov show they get wrong or find
  ambiguous. Verify can compare pinned digests with a fresh resolution.
  Doc 159 needs "every image reachable by a pin" as its prerequisite, and
  this provides it.
- **What remains:** helper images on their own version lines become sources
  of their own (doc 172b open question 2). A build per candidate is slow,
  so the build-based list runs once per bump, after the cheap tag check has
  passed.

### 4.4 How each design handles the hard cases

| Case | A | B | C |
|---|---|---|---|
| An image never appears | Listed every run; the newest ready release below it is bumped; no agent runs for it | Same, with the release date shown. No behaviour depends on age. A person adds `skip` to stop the listing | Same as B |
| Only one architecture is published | Not ready, if A checks both platforms | Not ready until both required platforms exist. Verify applies the same rule to every pinned image | Same, and from the built manifests, so chart images count |
| A version is withdrawn | Release deleted or re-marked pre-release: gone from the feed on the next run. Fix release published: it is the new newest | Same. Verify runs readiness again just before the pull request opens. A bump pull request whose target has left the candidate list gets `bump:needs-person` | Same, and the digest comparison catches a tag that was pushed again |
| Pre-releases | Unchanged: the feed's pre-release flag and the tag pattern (`detect.py:32`, `:94`) | Unchanged. The registry never supplies candidates, so an `-rc` image tag cannot become one | Unchanged |
| Several versions behind | Jumps to the newest ready release | Same, or one step at a time where `step` is set | Same as B |
| Upstream requires intermediate versions | Left to the agent (`brief.md:8`), with the fault in §6.2 | `step` in `sources.toml`; each step is its own bump, named for the version it reaches | Same as B, read from the package's upgrade rules |

Two cases stay with a person in every design. A release that is broken with
no upstream signal: the agent reports `held` and a person adds `skip`. A
platform that upstream drops for good: readiness should fail only for the
two required platforms and list any other dropped platform in the pull
request, which answers the housekeeping entry of 17 Nov. A hard failure
would hold the package on an old version for a platform Kix does not test.

## 5. What was built

Design B, in one pull request. Design A fixes the two reported cases and
adds a second copy of the tag grammar, leaves the agent able to override
the target, and keeps two definitions of readiness. Design C is left for
its own doc, when doc 159 starts. `readiness.py` and
`kix/packages/release-images.nix` are the first half of it.

The build differs from §4.2 in these ways.

- **Platforms.** A rule of "amd64 and arm64" would hold `mayastor` and
  `harbor` on their versions for good. Their upstreams publish amd64 only
  (15 pinned images, read from the registries on 23 Nov). The rule is: an
  image needs linux/amd64, and each other required platform that the image
  it replaces has (`needed` in `readiness.py`). Detection compares a
  candidate with the pinned image. Verify compares every default image
  with the same option at the base commit, which also answers the
  housekeeping entry of 17 Nov about comparing platforms across a bump.
- **The setting is `through`.** `detect.py` already uses "step" for the
  size of a move. `through = "minor"` is set for kubevirt.
- **Charts are not checked.** The chart of smartctl-exporter has a version
  line of its own, so a candidate release does not name a chart version.
  Cilium's chart shares the release version, and its images come from
  chart values. For both, detection takes the newest release as before,
  and the summary says the target was not checked against a registry.
- **Detection still runs weekly.** The daily schedule is a separate
  change, to make after the new detection has chosen targets on a real run.
- **A helper image whose version equals the package's** counts as part of
  the release, because the rule reads the version from the tag. A
  housekeeping entry records the case.

Built as designed: detection lists candidates and takes the newest ready
one, the agent no longer chooses the version, verify checks that the
package pins the target, `not-ready` opens an issue with the marker, and
the change record is named `changes/bump-<name>-<version>.md` (§6.5).

Checks at the time of the change:

- `versions.retag` gives back every default tag in use when asked for the
  version the tag names (`kix/lib/tests/units/lib-version-retag.nix`).
- `.github/bump/test_detect.py` replays the two cases of 23 Nov from
  recorded answers: the target for clickhouse is 26.8.44.3, and
  echo-server has no target.
- A run against the live registries with no dispatch, on 23 Nov at about
  21:30 UTC: echo-server waits on 1.30.7 and 1.30.8, snapshot-controller
  waits on 8.7.1, and clickhouse targets 26.8.45.6, which had been
  published by then.

## 6. Adjacent weaknesses

These are separate from the main question. Design B removes the first
three.

### 6.1 `not-ready` has no memory

A `not-ready` run is green and leaves no marker, so the next detect run
starts it again at once (§2.2; runs 45222774163 and 45222767945). Each
repeat also takes one of the five dispatch slots. In run 45219968501 the
two repeats were "started" while traefik, valkey, velero, and
victoria-metrics were "not started".

### 6.2 A version other than the target cannot be recorded

Not observed in a run. It follows from the code. `brief.md:7-8` lets the
agent reach a lower version. The pull request is still titled "Update
<package> to <target>", on the branch `bump/<package>-<target>`, with
`<!-- bump-target: <package> <target> -->` (`bump-agent.yml:80`, `:428`,
`:447`), and its body says "Upstream's newest release is" the target
(`:448`). After it merges, the package is still behind the target, and
`detect.py:219-220` skips the target because a pull request "names this
version". Markers are read from closed items too (`detect.py:159`). The
package then stays where it is until upstream releases something newer.
Stepping through intermediate versions stalls the same way after one step.

### 6.3 A missing amd64 image costs two full agent runs and then blocks

Not observed in a run. It follows from the code. When arm64 is published
before amd64, the agent's tests pass on arm64. The amd64 check is the last
verify step (`bump-agent.yml:360-364`), so it fails after the whole agent
run. A verify failure with Haiku or Sonnet starts the workflow again with
Opus for 120 minutes (`bump-agent.yml:485-508`), which cannot publish an
image. The second failure makes detection refuse that target until a person
acts (`detect.py:227-230`), including after the image appears. Step 3 of
the build order moves the same check to before the agent starts.

### 6.4 Five bumps a week

The schedule is weekly and the default limit is 5 (`bump-detect.yml:15`,
`:21`). On 23 Nov twelve sources were behind (summary of run 45219968501).
Doc 172a measured about 94 upstream updates a month across the package set.
The limit protects the runner, so the fix is the daily run in step 5 with
the same limit, which gives 35 slots a week.

### 6.5 Change record names collide

`brief.md:28` names the record `changes/bump-<name>.md`. A second bump
before a release finds the file taken (housekeeping entry in PR #291; the
echo-server report in run 45218840423). A daily run makes this more common.
Name the record `bump-<name>-<version>.md` before step 5.

### 6.6 Already recorded

Housekeeping entries of 19 Nov and 17 Nov: the amd64 check cannot see chart
or operator images (needs Design C), and no check compares platforms between
the old and new image (step 3 covers the two required platforms).

## 7. Not verified

- Why the scheduled detect run 45219968501 was created at 16:44 UTC on
  Monday when the cron is 06:00. The workflow file has had that cron since
  it was added on 19 Nov.
- §6.2 and §6.3 are read from the code. No run in the history shows either.
- Whether Docker Hub counts the readiness requests against its anonymous
  pull limit. `crane digest` sends a HEAD request, which Docker documents as
  free of the limit. I did not test it at the volume a daily run would
  make (about 125 image references across four registries).
- The shape counts in §3.2 come from grouping the evaluated default images
  by repository and tag. I did not open each package to confirm which
  helper images follow the release.
- That `versions.ofTag`'s grammar can be inverted for every tag in use.
  `distroless-v1.40.2` puts text before the version, and I did not test
  whether the grammar accepts it. Step 2's test settles this.
- The only real instance of case 2 is one ClickHouse run. The claim that it
  is common rests on ClickHouse's daily LTS releases and an image lag of
  about an hour, read from GitHub and Docker Hub on 23 Nov.

## 8. Open questions

1. **Where the upgrade path is declared.** `through` in `sources.toml` is a
   second place that describes an upgrade path. Doc 172 §4.5 proposes
   upgrade rules declared by the package. When those exist, detection
   should read them and the setting should go.
2. **Hourly or daily detection.** Doc 172b proposed hourly. Daily bounds
   the wait at a day and fits the daily batch (`bump-batch.yml:25`).
3. **A waiting release that fixes CVEs.** echo-server 1.30.7 fixes nine and
   had no image for five days. The summary shows it, and nobody is told.
   One standing issue that detection rewrites each run would make waiting
   releases visible without a threshold on age.
4. **Design C.** The release as data, with digests pinned by a script.
