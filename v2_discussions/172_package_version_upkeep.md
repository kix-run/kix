# 172: Keeping packaged software current, and what an upgrade promises

**Status:** Draft, with evidence from an experiment on 2026-11-13
**Related:** `155_platform_versions_and_compatibility.md` (§5.5 transition rules), `159_patched_images_pipeline.md`, `146_crd_vendoring_and_upgrades.md`, `170_instance_version_from_main_image.md`, issues #109 and #115

## 1. Problem

Each Kix package pins the version of the software it deploys: CoreDNS in
`coredns`, Valkey in `valkey`, and so on. Two things are missing.

**Nothing moves the pins.** No job compares a pinned version with upstream.
On 2026-11-13, 49 of 54 packages checked were behind their upstream. CoreDNS
was two minors behind, Valkey one major, CDI and KubeVirt four minors. Most
packages only go stale. Some stop working: GitHub stops sending jobs to a
runner more than 30 days behind, so `arc-runner-set` fails within a month of
a runner release.

**An upgrade promises nothing.** A user who upgrades Kix gets whatever
versions the new Kix library pins. If they skipped several Kix releases, one
deploy may move a piece of software across versions that upstream does not
support crossing in one step, or back to a version that cannot read its own
data. Kix checks neither, and no test covers an upgrade of an existing
install.

## 2. What exists

- **The version an instance runs is recorded.** A package publishes
  `out.version`, read from its image tag. The plan and the PackageInstance
  record carry it (doc 170). The plan already holds the old and the new
  version of each instance (`old_version` in `cli/kix/src/plan/diff.rs`).
- **Range checks.** `meta.k8s` and `meta.compatibleWith` check one build
  (`kix/lib/meta.nix`). Neither compares two builds.
- **Transition rules are designed and not built.** Doc 155 §5.5 says a rule
  about moving between versions runs where two builds are compared. This doc
  takes over its open question 4, where a package declares the rule.
- **A pipeline for security bumps is designed** (doc 159). This doc covers
  routine bumps and should share its parts.
- **CRDs follow a version.** `scripts/vendor-crds.py` re-vendors them and CI
  checks it (doc 146).
- **The upgrade deploy is written down for authors.** The `package-authoring`
  skill says to deploy the package from `main` on kind and then the change on
  top. The skill says nothing else about upgrading a package.

## 3. How much work this is

An agent measured a year of upstream releases (14 November 2025 to 13
November 2026) for every package that runs upstream software: 69 packages
from 61 distinct upstreams. It counted an update each time the newest stable
version moved up, which is the number of pull requests the process opens.

| Per month, per distinct upstream | Major | Minor | Patch | Total |
|---|---|---|---|---|
| Mean | 0.5 | 27 | 67 | 94 |
| Lowest and highest month | 0 to 2 | 22 to 32 | 38 to 106 | 61 to 134 |

- **Per package per month:** a mean of 1.75 updates (0.008 major, 0.49
  minor, 1.26 patch) and a median of 1.0. A few fast projects pull the mean
  up: n8n, reflector, ClickHouse, filebrowser, and metabase produce 37% of
  all updates.
- **Rule of thumb:** N packages gives about 0.8N to 1.3N patch, 0.35N to
  0.5N minor, and N/120 major updates a month.
- **Versions below 1.0:** 19 packages, where a minor step may break. With
  the majors, a possibly breaking update arrives about 10 times a month.
- **Batching:** taking patches at most once a week per package gives 76
  pull requests a month. At most once a month gives 58.
- **Older lines:** a third of all stable releases are fixes on older lines,
  which a package that follows the newest line never takes.

The method, data, and limits are in `172a_upstream_release_rates.md`.

## 4. Proposal

### 4.1 Detection is a script, run daily

A script lists every package's pinned version and the latest stable upstream
release, and writes the difference as data. It needs each package to name
its upstream in one field. It decides nothing and opens no pull request.

The script also hands the agent its target version. In the experiment, one
run of twelve that looked the target up itself chose a release upstream had
already replaced because its images were broken.

### 4.2 The bump is done by an agent, one pull request per package

A version bump is rarely one line. In the experiment, CDI moved its metrics
port and put a login on its metrics page, which would have broken the
package's health probes. Grafana started shipping plugins in a folder the
package mounted over, which hid every data source. External-dns changed how
it picks a hostname. None of these were in a place a version-only change
would touch.

The agent gets three things:

1. **The target version**, from 4.1.
2. **A page of notes** that hold for any package: read upstream's own
   deployment files between the two versions, list every image, check the
   digest lookup against the old pin, deploy the old version before editing,
   check what the software itself reports after the deploy, test going back.
   These belong in the `package-authoring` skill as an "upgrading a package"
   section.
3. **One command that defines done.** It runs every deterministic check
   quietly, prints one line per check, and fails if an old image digest
   remains or a test fails. The brief says the work is finished only when
   the command passes. §5 shows why this matters more than the wording of
   the notes.

### 4.3 Cadence, and who merges

| Bump | Batched | Merged by |
|---|---|---|
| Security fix for a pinned version | never, same day | a person |
| Patch | weekly, one pull request per package | a person, or automatically once 4.4 is trusted |
| Minor | weekly, one pull request per package | a person |
| Major, or a minor below 1.0 | on its own | a person, with the upgrade rule reviewed |

A package that breaks when it falls behind, such as `arc-runner-set`,
declares a maximum age. Detection treats passing it as a security fix.

### 4.4 The upgrade test

For a pull request that changes a package's version, on a new kind cluster:

1. Deploy the package as it is on the base branch.
2. Write state. A package that holds data ships a small fixture: one Job
   that writes, and one that reads back.
3. Deploy the pull request's package over it with a plain `kix deploy`.
4. Check that the deploy finished, the health probe passes, the read-back
   Job passes, and the software reports the new version.
5. Where the package declares an upgrade rule, deploy from a version the
   rule forbids and check that the plan refuses and names the route.

Each step is deterministic, so a workflow can run it. Today an agent runs it
by hand, and each agent chooses its own test cluster and its own scope. In
the experiment that choice was the largest source of difference between
runs. A standing upgrade test cluster per package removes the choice.

Needed first: a workflow that runs kind in CI, a probe on every stable
package (about one package in six has one), and the fixture on every stable
package that holds data.

### 4.5 Upgrade rules, and the refusal

A package declares which moves are allowed. The cases seen so far:

- "from 8.0 or newer" (a floor),
- "at most two minors per step" (StackGres, doc 155),
- "one major at a time" (many databases),
- "through 2.4 first" (a named stop),
- "cannot go back" (Valkey 9 writes files that 8.1 refuses; Harbor and CDI
  refuse a downgrade outright).

`kix plan` and `kix deploy` compare the recorded version of each instance
with the version about to deploy and refuse a move the rule forbids. The
error names the instance, both versions, the rule, and the next step.

"Cannot go back" was the rule the experiment met most often, and it also
applies to `kix rollback`. Upstream rarely states these rules in a form a
program can read. For Valkey, CDI, and Harbor the agents had to learn them
from source or by testing, so the agent that writes the bump records the
rule.

The refusal is only useful if the user can take the intermediate step:

- **Pin the instance** to the intermediate version, deploy, then remove the
  pin. This needs the current package to still support that version.
- **Deploy an older Kix first.** Kix already has required stops for its own
  cluster state. A per-package stop is the same idea at a smaller scope.

Limit: the check reads the version the image tag names. It does not see
state the tag does not show.

### 4.6 Checking what the software reached

A deploy can report success while the software is on another version. With
CDI, the deploy returned before the operator had started upgrading, and a
downgrade "succeeded" while the operator refused it and changed nothing.
The readiness rule a package declares reads one status field, and nothing
ties that field to the change the deploy made. Issue #115 holds the design
question and an investigation that recommends letting a rule require
several fields. The upgrade rules in 4.5 and this check cover each other's
gaps: the plan refuses what a package says cannot work, and the deploy
notices when the software did not follow.

### 4.7 What Kix promises

- **Stable packages.** The upgrade from the previous Kix minor release is
  tested (4.4) before it is released. A move upstream does not support is
  refused with the route. A bump the user must act on has a breaking change
  record.
- **Experimental packages.** Bumped on the same cadence. The upgrade test
  runs where a probe exists. No promise beyond the change record.

## 5. Experiment: which model can do a bump

Run on 2026-11-13 and 14. Each run got one package, its own worktree, and
its own kind cluster, and had to read the release notes, deploy the old
version, write state, make the bump, run the checks, deploy the new version
over the old, verify, and report. I checked each branch against the others
and ran the checks myself. Costs are API list prices from recorded token
counts. The Hydrogen figures assume cached input costs a tenth of fresh
input, and the Haiku range reflects its two price tiers.

### 5.1 Round one: the same brief, no notes

CoreDNS 1.13.1 to 1.15.0 (stateless) and Valkey 8.1.10 to 9.1.3 (holds
data, one major).

| Model | CoreDNS | Valkey | Minutes | Would pass CI | What stood out |
|---|---|---|---|---|---|
| Luna (GPT-6) | $0.07 | $0.12 | 11 | no | Fastest and most candid. Touched no file outside the package. Missed Valkey's one-way data format. |
| Haiku 5.5 | stalled | $0.20 to $1.00 | 11 | no | Tested going back for real. Edited snapshots by search and replace, which gave wrong files. |
| Sonnet 5.5 | $0.62 | $1.08 | 7 to 8 | no | Sound upgrade. Two of four snapshots missed. No network policy in the test. |
| Hydrogen (Gemini 4) | about $3.20 | about $2.50 | 19 to 23 | CoreDNS yes, Valkey no | Ran the most checks, and found the snapshots by running the test. Did not test going back. |
| Opus 5.5 | $6.72 | $6.64 | 14 to 20 | yes | Tested under network policy with every topology. Found the setting that lets 8.1 read 9's files, and its limit. Found issue #109. |

All five made the same package edit. They differed in everything around it:
files outside the package, how real the test was, and how far they dug.

### 5.2 With a page of notes

The notes were written from round one's misses.

| Run | Cost | Minutes | Result |
|---|---|---|---|
| Valkey, Haiku | $0.20 to $0.90 | 27 | Matched Opus's round-one branch: all snapshots identical, both topologies, network policy, four going-back cases. |
| Valkey, Sonnet | $1.21 | 18 | Matched Opus's round-one branch. |
| Valkey, Luna | $0.14 | about 12 | Snapshots identical to Opus's. Found the one-way format and tested the rollback through Kix itself. One topology only. |
| Harbor 2.15.2 to 2.15.5, Sonnet | $1.19 | 16 | Six images moved, database migration observed, downgrade refusal tested. |
| Harbor, Haiku | none | stalled | Stopped while waiting on its own watcher. |
| CDI 1.62 to 1.66, Haiku | $0.77 | 39 | Found the probe and port change. Missed that the deploy returned early. |
| CDI, Sonnet | $1.62 | 18 | Found the probe change and both halves of issue #115. |
| CDI, Opus | $5.68 | 24 | The same, and changed the readiness rule and reran the upgrade to prove it. |

With notes, Haiku, Sonnet, and Luna each produced a Valkey branch as good as
Opus's unaided one. On CDI, the hardest package, all three Claude models
produced a working upgrade. They differed in what else they noticed.

### 5.3 Luna on packages the notes had never seen

The notes were frozen, then tested on four untouched packages, three Luna
runs each, with one Sonnet run per package as the reference. The brief named
only the package folder and its pinned version.

| Package | Bump | Package edit right | Would pass CI | Luna cost | Sonnet reference |
|---|---|---|---|---|---|
| `metrics-server` | patch | 3 of 3 | 3 of 3, but 0 of 3 updated `ROADMAP.md` | $0.05 to $0.10 | $0.53 |
| `external-dns` | minor | 3 of 3 | 1 of 3 | $0.10 to $0.13 | $0.96 |
| `prometheus-operator` | three minors, CRDs | 2 of 3 (one wrong target) | 1 of 3 | $0.07 to $0.09 | $1.30 |
| `grafana` | two minors, holds data | 3 of 3 found the hidden plugins | 3 of 3 | $0.32 to $0.44 | $2.37 |

- **The package edit is reliable.** Where Luna re-vendored CRDs and roles,
  the files matched the reference exactly.
- **The misses are outside the package and in slow checks.** A unit test
  that cites the next version, a docs excerpt, a roadmap line. No Luna run
  finished the library tests unprompted. They take three minutes and print
  19,000 warning lines for a passing run, so Luna interrupted them and said
  so.
- **Depth differs.** On Grafana all three Luna runs added an init container
  that copies the plugins back. Sonnet removed the mount that hid them,
  which is the fix at the cause.

### 5.4 The same runs with one command as the definition of done

`external-dns` again, three Luna runs, same notes, and one added paragraph:
the work is finished only when a completeness script prints PASS.

| | Notes only | Notes plus the command |
|---|---|---|
| Edited the unit test that had to change | 1 of 3 | 3 of 3 |
| Reported the checks passing | n/a | 3 of 3 |
| Minutes | 10 to 13 | 16 to 24 |
| Cost | $0.10 to $0.13 | $0.14 to $0.31 |

The agents ran the command 10 to 18 times each while fixing what it
reported. A quiet command with a pass or fail line did what a firmer
instruction had not.

### 5.5 What this suggests

- **Most of the gap between models in round one was missing instructions
  and missing tooling.** Notes closed the gap on the package they were
  written from. The command closed most of the rest on a package they had
  never seen.
- **Use the cheap model for the bulk and a stronger one where depth
  matters.** A reasonable split: Luna or Haiku for patch bumps, Sonnet for
  minors, and Sonnet or Opus for majors, operators, and packages that hold
  data. At about 94 bumps a month, the agent cost is roughly $20 a month at
  Luna's price, $115 at Sonnet's, and $630 at Opus's.
- **Run the same command again after the agent.** It is cheap, and CI does
  it anyway.
- **Each number here is from one to three runs.** Treat the direction as
  evidence and the exact counts as provisional.

## 6. What the runs found in Kix

- **Issue #109:** a build with `--flake ./clusters` returned the old result
  after a package file changed. Reproduced, and fixed on `main` since.
- **Issue #115:** a deploy reports an operator ready before it has reached
  the version asked for, and after it has refused one.
- **The library tests print 19,000 warning lines** when they pass. Agents
  stop them. Logged in `housekeeping/`.
- **A version bump changes files that nothing connects to the package:**
  CLI snapshots, docs excerpts, unit tests that cite a version, the
  roadmap. Logged.
- **The change record kinds do not say what a one-way data change is.**
  Across the runs on Valkey, CDI, and Harbor the models chose `note`,
  `silent`, `changed`, and `security` for the same facts. Logged.
- **Many agents on one machine collide.** kind switches the shared
  kubeconfig's current context, port-forwards clash, and each worktree
  builds its own 2.4 GB Rust cache, which filled a disk. Logged.
- **The `kubevirt` package likely has the same readiness gap as `cdi`.**
- **Grafana 13.3 hides its data sources behind a mount the package adds,**
  while the pod stays ready. Only a data-source health call shows it.

## 7. Open questions

1. **The form of an upgrade rule.** A `meta.upgrade` with a few fixed
   shapes (floor, step size, named stops, cannot go back), or a function of
   the old and new versions. Fixed shapes can be printed in an error.
2. **How many upstream versions a package supports.** The pin route in 4.5
   needs the package to run the intermediate version.
3. **Where the upstream of a package is named.** A new `meta` field, or the
   image reference plus a table.
4. **Which image is the version** when a package pins several, and how
   sidecar and helper images are kept current. The release count in §3
   covers main images only.
5. **What a one-way data change is** among the change record kinds.
6. **Automatic merge of patch bumps.** What evidence makes 4.4 trusted
   enough, and whether stable packages are ever included.
7. **Shared parts with doc 159.** Detection, the kind verification, and the
   agent queue appear in both.
8. **The cost of the completeness command per worktree.** The snapshot test
   needs a cold Rust build. Share one build cache, or run it only when the
   package is in the example cluster.

## 8. Next steps

1. Put the completeness command and the "upgrading a package" section in
   the repository (branch `upkeep-tooling`).
2. Decide the upgrade rule form, with "cannot go back" as the first rule.
3. Write the detection script and name each package's upstream.
4. Quiet the library tests at the source.
5. Add a standing upgrade test cluster for each stable package.
6. Review and merge the package bumps the experiment produced (§9).

## 9. What the experiment left behind

Branches, all local and unpushed, in worktrees under
`/scratch/worktrees/upkeep/`. The first named is the one to review.

| Package | To | Branches |
|---|---|---|
| `coredns` | 1.15.0 | `upkeep-coredns-opus`, `upkeep-coredns-hydrogen` |
| `valkey` | 9.1.3 | `upkeep-valkey-opus`, `upkeep-valkey-sonnet2`, `upkeep-valkey-haiku2`, `upkeep-valkey-luna2` |
| `harbor` | 2.15.5 | `upkeep-harbor-sonnet` |
| `cdi` | 1.66.1 | `upkeep-cdi-sonnet`, `upkeep-cdi-opus` (its readiness change waits on issue #115) |
| `metrics-server` | 0.9.1 | `upkeep-ms-sonnet` |
| `external-dns` | 0.24.0 | `upkeep-edns-sonnet`, `upkeep-edns-luna3-1` |
| `prometheus-operator` | 0.95.2 | `upkeep-promop-sonnet` |
| `grafana` | 13.3.1 | `upkeep-graf-sonnet` |

Each branch was cut from `main` at `7661b16b` and needs a rebase, the Argon
copy pass, and a review before it merges. The notes, briefs, completeness script, and the release count's script
and data are in `/scratch/worktrees/upkeep/_keep/`.
