# 172b: Running the package bump workflow

**Status:** Draft
**Related:** `172_package_version_upkeep.md` (the proposal this doc makes runnable), `172a_upstream_release_rates.md`

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

**The upstream of each package.** A new `meta.upstream` in the package:

```nix
meta = {
  version = release;
  upstream.git = "https://github.com/kubernetes/ingress-nginx";
  # Only where a release tag is more than the version.
  upstream.tag = "controller-v{version}";
};
```

`upstream.git` is the URL of upstream's git repository. The script lists
its tags over git, which works the same on GitHub, GitLab, Gitea, and a
self-hosted server. It needs no forge API and no token.

`upstream.tag` is the shape of a release tag, with `{version}` where the
version sits. The default is `{version}` with an optional leading `v`,
which fits most upstreams. Other examples are `n8n@{version}` and
`gha-runner-scale-set-{version}`. The script reads the `{version}` part
with the same version grammar that `meta.version` uses, and drops a tag
whose version has a prerelease suffix such as `-rc1`. 
Three more fields cover the upstreams that need them:

- `upstream.scheme = "calendar"` for an upstream that versions by date,
  where the steps are not major, minor, and patch.
- `upstream.separator = "_"` for tags such as PostgreSQL's `REL_18_7`,
  with the shape `REL_{version}`.
- `upstream.within = "major"` or `"minor"` keeps detection inside the
  pinned major or minor line. Metabase needs `"major"` (§2.2). The
  `echo-server` package follows nginx's stable branch, which is one minor
  line, so it sets `"minor"`. A move to the next line is then a person's
  decision.

The upstream is a fact about the software, like the version beside it. In
the package, it is reviewed with the package, it moves with the package
when the folder moves, and a package outside this repository can carry it.
Detection already evaluates every package to read `meta.version`, so
reading one more field costs nothing. A stable package with no
`meta.upstream` fails a library test, so a new package cannot be left out.
The experiment collected the repository and tag shape for 69 packages
(`/scratch/worktrees/upkeep/_keep/release-rates/fetch.py`), which fills the
field for the current set.

Packages that name the same repository move together and share one queue
item.

**How careful a bump must be.** The script derives this from what the
package already says, so there is no field to keep in step:

- `data`: the package sets `meta.lifecycle = "stateful"`.
- `operator`: the package ships CRDs.
- `plain`: every other package.

**Holds.** A small data file, `kix/packages/bump-holds.toml`, lists the
packages held at a version, each with a reason and an end date. A hold is
a decision about this repository's schedule. It changes often and says
nothing about the software, so it stays out of the package.

### 2.2 The script

The script is Python, run with `uv`, like `scripts/vendor-crds.py`. It
reads and orders versions with the `packaging` library.

The choice was tested on the real tags of the 62 upstreams, 25,819 tags
listed over git on 2026-11-14. Each candidate picked the newest stable tag
for each upstream, and the answer was compared with the hand-tuned
patterns of the release count in doc 172a
(`/scratch/worktrees/upkeep/_keep/version-libs/`):

| Reader | Right, of 62 | Wrong on |
|---|---|---|
| `packaging` | 60 | CoreDNS, Metabase |
| a ten-line reader of the `meta.version` grammar | 60 | the same two |
| `semver`, `semantic_version` (strict) | 59 | Metabase, and they cannot read PostgreSQL `18.7` or ClickHouse `26.8.37.168` |
| `univers`, `semantic_version` in its lenient mode | 59 | CoreDNS, Metabase, and they read `19.BETA1` as stable |
| `looseversion` | 31 | every upstream with a release candidate or a second family of tags |

No library was right alone. Two rules in the script close the gap, and
they are needed whichever library reads the versions:

- **At least two parts.** CoreDNS has an old tag `v011`, which reads as
  version 11 and beats `1.15.0`. A moving tag such as `v2` fails the same
  way. The rule cannot ask for the same number of parts as the pinned
  version, because ten upstreams mix lengths. Metabase publishes both
  `0.65.4` and `0.65.4.4`.
- **A limit on the line** (`upstream.within`, §2.1). Metabase tags its
  paid edition `v1.x` beside the open-source `v0.x`. Both are stable
  releases, so no version reader can tell them apart.

With those rules, `packaging` was right for 62 of 62 in a second run. It and the ten-line
reader disagreed on 8 tags of the 19,619 that fit a tag shape, all of the
form `17.0.0-6`, which `packaging` reads as a later release of `17.0.0`.
The script refuses that form and reports the tag, so the two agree on
every tag.

`packaging` is kept because it already orders build suffixes such as
Grafana's `+security-01` and recognises every prerelease spelling, which
the script would otherwise have to write and test. It follows Python's
version rules, and Kix compares versions in Nix and Rust with its own. A
test runs the three on one list of versions so that they cannot drift
apart.

### 2.3 Rules

For each package the script lists the upstream's tags and picks a target.
Every rule is a comparison a program can make:

1. **Stable releases only.** The tag has the shape `upstream.tag` gives.
   Its version has no prerelease suffix and at least two parts, and it is
   inside `upstream.within` where that is set.
2. **The newest version.** The target is the highest stable version. The
   step from the pinned version is patch, minor, or major. A minor below
   1.0 counts as major, as in doc 172.
3. **The image exists.** The script looks the target's tag up in the
   registry and records the digest. A tag with no image is not a target
   yet. Upstream can push a tag before it publishes anything, and this
   rule covers that.
4. **Holds.** A held package is not a target. A hold whose end date has
   passed fails the script, so that holds get removed.

There is no waiting period. A bump is queued as soon as the tag and its
image exist. A user who wants to stay some days behind chooses when to
upgrade Kix. Upstream sometimes replaces a release within a day, and the
experiment met one such case. When upstream removes the tag, the reconcile
step closes the bump and queues the newer version (§3). When upstream
leaves the tag in place, the newer version is picked up after the open
pull request merges or closes, or sooner if a person closes it.

### 2.4 Output

A list of pending bumps as JSON:

```json
{ "package": "valkey", "pinned": "8.1.10", "target": "8.1.11",
  "tag": "8.1.11", "step": "patch", "care": "data",
  "git": "https://github.com/valkey-io/valkey", "digest": "sha256:…" }
```

When the script cannot decide for a package (a tag it cannot read, a
registry that does not answer), it reports that package as broken and
carries on with the others. A broken package starts no agent.

### 2.5 Cost of a run

One run lists the tags of about 61 repositories over git and makes one
registry lookup for each new target. No forge API is involved, so no API
rate limit applies. An hourly run is cheap. Most runs find nothing and end
there.

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
| the target's tag is gone upstream | an issue or an open pull request for it | closes both with a comment, and the next run queues the newer version |
| package current | an open issue | closes it |
| package broken | nothing | opens or updates one `bump:detection` issue |

**One open pull request per package.** While a bump for a package waits
for review, a newer release starts no second agent. When the pull request
merges or closes, the next detection run finds whatever gap is left. This
keeps a package that releases three patches in a week from costing three
agent runs. An urgent item is the exception (§6).

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
   version, the target, the digest, upstream's repository and the two tags,
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

The first model comes from the step and how careful the bump must be
(§2.1):

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

## 6. Items from other sources

Detection is one source of queue items. The queue, the runner, the kind
verification, and the pull request that moves a pin do not depend on why
a bump is wanted. Each item carries a `source` field, and another tool can
add items of its own.

An item can be marked urgent with the label `bump:urgent`. An urgent item
goes to the front of the queue, and may replace
an open pull request for the same package. A security fix is the main
case. This workflow does not decide that a release is a security fix: a
version number does not say so. The mark comes from the item's source, or
from a person.

## 7. Open questions

1. **`meta.upstream` is new package surface.** It needs a row in the
   package reference, an item in the `package-review` checklist, and a
   decision on packages with no single upstream release line, such as
   `echo-server`. A value of `null` with a comment may be enough.
2. **Several upstreams in one package.** A package that pins images from
   two projects has one `meta.version` and would have one `meta.upstream`.
   Doc 172, question 4, asks the same about helper images.
3. **A public repository.** A self-hosted runner that holds model logins is
   safe while only maintainers can start its workflows. If the repository
   becomes public, the bump workflow must never run on a pull request from
   a fork.
4. **Subscription limits.** The cost figures in doc 172 are API prices. The
   runs go through subscriptions, which have usage limits. The cap of six
   bumps an hour is a guess until a week of real runs shows the usage.
5. **Packages that move together.** Packages with the same upstream
   repository share one queue item. It is not settled whether that is one
   agent run and one pull request, or one run per package in a fixed order.
6. **The build cache.** Each checkout builds its own 2.4 GB Rust cache for
   the snapshot test (doc 172, question 8). Two slots that reuse two fixed
   checkout paths would keep the caches warm and remove the cost.

## 8. Build order

Each step is useful without the next.

1. **`meta.upstream` on every package and the detection script**, tested against
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
