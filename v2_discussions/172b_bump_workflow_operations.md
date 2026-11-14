# 172b: Running the package bump workflow

**Status:** Draft
**Related:** `172_package_version_upkeep.md` (the proposal this doc makes runnable), `172a_upstream_release_rates.md`, `159_patched_images_pipeline.md` (shares the queue and the runner)

## 1. Summary

Doc 172 says what a bump is, who merges it, and which model can write it.
This doc says how the work runs from day to day.

A script decides which packages need a bump. It uses no model, so it can
run every hour for the price of a few API calls. An agent starts only when
the script has put a bump in the queue. A runner takes bumps from the
queue, at most two at a time, and checks each agent's work itself before it
opens a pull request.

```
every hour                          when the queue has work
┌───────────┐   ┌──────────────┐    ┌────────────────────────────────┐
│ detection │──▶│  reconcile   │───▶│ runner (2 slots)               │
│ (script)  │   │  with issues │    │ agent ─▶ check ─▶ pull request │
└───────────┘   └──────────────┘    └────────────────────────────────┘
  no model         no model           a model, then checks with none
```

## 2. Detection

### 2.1 Inputs

**The version each package pins.** Every package sets `meta.version`. One
evaluation of the Kix library lists it for all packages.

**The upstream of each package.** A data file, `kix/packages/upstreams.toml`,
with one entry per package:

```toml
[valkey]
repo = "valkey-io/valkey"
care = "data"            # plain | operator | data

[ingress-nginx]
repo = "kubernetes/ingress-nginx"
tag = '^controller-v(\d+\.\d+\.\d+)$'

[victoria-metrics-agent]
repo = "VictoriaMetrics/VictoriaMetrics"
group = "victoria-metrics"   # packages that move together
```

The experiment already built this table for 69 packages, with the tag
pattern for each upstream that needs one
(`/scratch/worktrees/upkeep/_keep/release-rates/fetch.py`). A test fails
when a package has no entry, so a new package cannot be left out.

`care` picks the first model (§4.3). The script cannot work it out from the
package: nothing in a package says that it holds data.

### 2.2 Rules

For each package the script fetches the upstream's releases and picks a
target. Every rule is a comparison a program can make:

1. **Stable releases only.** The tag matches the pattern, and upstream has
   not marked it as a prerelease.
2. **The newest version.** The target is the highest stable version. The
   step from the pinned version is patch, minor, or major. A minor below
   1.0 counts as major, as in doc 172.
3. **A waiting period.** A release must be three days old. In the
   experiment, one release was replaced a day later because its images were
   broken.
4. **The image exists.** The script looks the target's tag up in the
   registry and records the digest. A release with no image is not a
   target.
5. **Holds.** An entry can hold a package at a version, with a reason and
   an end date. A hold whose date has passed fails the script, so that
   holds get removed.

### 2.3 Output

A list of pending bumps as JSON:

```json
{ "package": "valkey", "pinned": "8.1.10", "target": "8.1.11",
  "step": "patch", "care": "data", "released": "2026-11-09",
  "digest": "sha256:…", "notes_url": "https://github.com/valkey-io/valkey/releases/tag/8.1.11" }
```

When the script cannot decide for a package (a tag it cannot read, a
registry that does not answer), it reports that package as broken and
carries on with the others. A broken package starts no agent.

### 2.4 Cost of a run

One run makes about 61 requests to GitHub and one registry lookup for each
new target. Requests that send the last response's ETag do not count
against the rate limit when nothing changed. An hourly run is cheap. Most
runs find nothing and end there.

## 3. The queue

The queue is GitHub issues, one for each pending bump, labelled `bump`. An
issue is the place where a person can see the state, read the failed
attempts, and stop the work.

After detection, a reconcile step compares the list with the issues and
pull requests that exist. It is safe to run any number of times:

| Detection says | Exists | Reconcile does |
|---|---|---|
| bump pending | nothing | opens an issue, labelled `bump:queued` |
| bump pending | an issue for an older target, no pull request | updates the issue to the new target |
| bump pending | an open pull request for the package | nothing (see below) |
| package current | an open issue | closes it |
| package broken | nothing | opens or updates one `bump:detection` issue |

**One open pull request per package.** While a bump for a package waits
for review, a newer release starts no second agent. When the pull request
merges or closes, the next detection run finds whatever gap is left. This
keeps a package that releases three patches in a week from costing three
agent runs. A security fix is the exception (§7, question 2).

**Labels hold the state:** `bump:queued`, `bump:running`, `bump:failed-1`,
`bump:failed-2`, `bump:needs-person`, and `bump:hold`. The runner takes
only `bump:queued`. A person stops a bump by adding `bump:hold`, and
restarts one by setting `bump:queued`.

## 4. The runner

### 4.1 Where it runs

A GitHub Actions workflow on a self-hosted runner on Adam's machine. The
repository already uses self-hosted runners for its other workflows. This
runner needs its own label, because it is the only one that holds the
logins for the model CLIs (Codex for Luna, Claude Code, and Antigravity).
Those logins are subscriptions tied to a home directory, and they do not
move to a hosted runner.

The detection workflow runs on a schedule. When the queue has work, it
starts the bump workflow with the queued issues as a matrix. The matrix
runs two at a time and takes at most six issues per run. The rest wait for
the next hour.

### 4.2 One bump, step by step

The workflow owns every step that a program can do. The agent does only
the package change.

1. **Check the machine.** Stop with no failure recorded if free disk is
   under 50 GB.
2. **Set up.** Check out a branch `bump/<package>-<target>` from `main`,
   outside any other checkout. Create a kubeconfig file and a kind cluster
   that belong to this run alone, named after the issue number.
3. **Run the agent** with a time limit of 45 minutes. The brief is a
   template filled from the detection record: the package, the pinned
   version, the target, the digest, the link to upstream's release notes,
   the "upgrading a package" section of the `package-authoring` skill, and
   the sentence "the work is finished when `scripts/check-bump.sh` prints
   `check-bump: PASS`".
4. **Check the work.** The workflow runs `scripts/check-bump.sh` itself.
   The agent's own report of a pass does not count.
5. **Run the upgrade test** (doc 172 §4.4), once it exists as a script.
6. **Run the Argon copy pass** on the change record, then run step 4 again.
7. **Open the pull request.** It names the issue, the model, the cost, and
   what the agent reported about breaking changes and going back. Labels:
   `bump` and the step (`bump:patch`, `bump:minor`, `bump:major`).
8. **Clean up, always.** Delete the kind cluster, the checkout, and the
   build cache for it. The experiment filled a disk in one night because
   nothing did this.

### 4.3 Which model, and what happens on failure

The first model comes from the step and the `care` field:

| Bump | First | Then | Then |
|---|---|---|---|
| patch, `plain` | Luna | Sonnet | a person |
| minor, `plain` | Sonnet | Opus | a person |
| major, or any `operator` or `data` package | Sonnet | Opus | a person |

A failure is a `check-bump: FAIL`, a failed upgrade test, or the time
limit. The runner then:

1. posts the last lines of the failed check on the issue,
2. moves the label from `bump:queued` to `bump:failed-1`, and
3. starts the next model from a clean branch, with the failed check's
   output added to the brief.

The next model does not continue the failed branch. A branch that failed
can hold a wrong idea that the next model would keep.

After the last model fails, the issue gets `bump:needs-person` and no agent
touches it again. This matters more as detection runs more often: without
it, a bump that cannot pass would start a new agent every hour.

### 4.4 Keeping an open pull request current

Bump pull requests go stale while they wait, mostly in the CLI snapshot
files that several bumps change. A refresh job rebases the branch,
regenerates the snapshots, and runs `scripts/check-bump.sh`. It uses no
model. If the rebase has a conflict inside the package, the job labels the
pull request for a person.

## 5. Review and merge

The runner never merges. Pull requests arrive as they pass, and a person
reviews them in a batch. The weekly rhythm in doc 172 §4.3 becomes the
rhythm of review, with the queue filled in the background.

A weekly digest issue lists what is waiting: pull requests by step, bumps
that need a person, packages on hold, and packages detection could not
read.

## 6. What doc 159 shares

Doc 159 finds work from CVE feeds, and this doc finds it from upstream
releases. After that the two need the same parts: a queue, a runner with
isolation and cleanup, the kind verification, and a pull request that
bumps a pin. Build those here, with a `source` field on each queue item,
and let doc 159 add items of its own.

## 7. Open questions

1. **Where the upstream is named.** This doc proposes one data file. The
   other choice is a field in each package's `meta`. A file keeps tag
   patterns and holds out of the package, and a script can read it without
   an evaluation.
2. **Security fixes.** A release that fixes a CVE should skip the waiting
   period and the one-pull-request rule. Detection cannot tell from a
   version number that a release is a security fix. Doc 159's feed can.
   Until it exists, a person adds a `bump:security` label by hand.
3. **A public repository.** A self-hosted runner that holds model logins is
   safe while only maintainers can start its workflows. If the repository
   becomes public, the bump workflow must never run on a pull request from
   a fork.
4. **Subscription limits.** The cost figures in doc 172 are API prices. The
   runs go through subscriptions, which have usage limits. The cap of six
   bumps an hour is a guess until a week of real runs shows the usage.
5. **Packages that move together.** `group` lets several packages share
   one bump. It is not settled whether that is one agent run and one pull
   request, or one run per package in a fixed order.
6. **The build cache.** Each checkout builds its own 2.4 GB Rust cache for
   the snapshot test (doc 172, question 8). Two slots that reuse two fixed
   checkout paths would keep the caches warm and remove the cost.

## 8. Build order

Each step is useful without the next.

1. **The upstream table and the detection script**, tested against
   recorded upstream responses. Run it by hand and read the list.
2. **Reconcile, in a mode that prints what it would do.** Turn on the
   hourly schedule once the printed actions look right for a few days.
   From here the issues alone are a live list of what is behind.
3. **The bump workflow, started by hand** for one issue at a time. It
   depends on pull request #118 for `scripts/check-bump.sh`.
4. **Start it from the queue**, with a cap of two bumps a day at first.
5. **The failure ladder** and `bump:needs-person`.
6. **The refresh job and the weekly digest.**
7. **The upgrade test**, when doc 172 §4.4 has its script.
