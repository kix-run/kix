# 140: Catalogue versions and upgrade windows

**Status:** RFC / Provisional. The direction in §5 is a first landing, not a decision. Expect it to move.
**Related:** `129_scaling_axes_fleet_and_linking.md`, `129a_grounding_field_and_prior_art.md`, `45_multi_team_and_operator_models.md`, `139_external_inputs_and_resolutions.md`, `archive/138_values_that_vary_per_deploy.md`, `business_discussions/51_managed_kix_option_space.md`

---

## 1. Problem

Lithus runs Kubernetes clusters for clients. Every cluster in the monorepo
builds against one shared `kixpkgs` flake input (`monorepo/flake.nix:102-113`,
`:529-550`), so a bump moves every cluster's build at once.

A managed service needs the opposite. One client should be able to sit on a
known-good platform revision while another takes the newest, and each should
move inside a window that was agreed rather than whenever someone bumps a lock
file.

Doc 129 named this and left it undesigned. Its fleet layer gets exactly one
global semantic computation, **pin coherence**: which package and input
versions each cluster builds against, skew report first, resolver later. 129a
adds the reason to build it rather than let it grow: no workspace layer in
build-system history stayed computation-free.

129 frames skew as a defect to report. This doc starts from the opposite
premise. For a managed service, controlled skew is the product.

---

## 2. What the code actually permits

Findings from a code and experiment pass on 2026-09-10. The experiments used a
mixer that fed a lib tree and a package tree from different revisions into one
evaluation.

### 2.1 A package is an unapplied function

`packages.<name>` is a bare `import`, not a finished value
(`kixpkgs/flake.nix:100-115` for `forPkgs`, `mkFlake.nix:22-27` for the
catalogue). The shape is `{ scope, lib, kix? } -> { meta, options, build, ... }`.
Of the upstream packages, 39 take `{kix, lib, scope}`, 24 take `{lib, scope}`,
and `cilium-external` is a bare attrset.

The lib binds the package at instantiation, in phase 1, passing its own
`scope` and `lib`, and its own `kixlib` as `kix` only when the function asks
for it (`kix/lib/eval/resolve.nix:203-221`). No package imports the lib by
path. `instances.<ns>.<name>.package` is `types.raw`
(`kix/lib/modules.nix:31-40`), so the module system treats a package as
opaque.

The catalogue is therefore not special. A cluster can overlay it with
`packages // { ... }`, and the monorepo already does the equivalent by
importing private packages by relative path
(`monorepo/client/lithus/clusters/lab1/kix/cluster.nix:23-27`).

### 2.2 Lib and catalogue cannot be versioned apart

Mechanically anything mixes. Semantically it breaks in both directions within
about six weeks of drift.

| lib | packages | result |
|---|---|---|
| Sept (HEAD) | Jul 29 | ludo-kind fails, 9 assertions (`distinctSameKindLabels`, `monitorSelectorMatchesService`, Service matches no workload) |
| Jul 29 | Sept | `attribute 'keys' missing` at `kix/packages/cilium/default.nix:240`; `kix.keys` landed in `66091fb` and 9 packages now use it |
| Sept | any | `test-minimal` (coredns) identical output in every combination |

A newer lib gets stricter about package output. Newer packages adopt
vocabulary an older lib lacks. Simple packages survive; the full catalogue
does not.

**A version has to be a revision of the whole tree.** Choosing a lib version
and a catalogue version separately is not a supported axis.

### 2.3 A lib-only change can rewrite every identity

Same coredns package, July lib against September lib: all 11 resources change
identity, entirely from the `kix.dev` to `kix.run` rename. Two libs that
differ only by refactor (Jul 16 against Jul 29) produce identical output.

So an upgrade diff can legitimately be every resource in the cluster. That
collides with issue #85, where shared-resource ownership flips on any hash
change.

### 2.4 CLI compatibility fails in both directions, and both are already in the code

- Old CLI, new lib: partial apply. The guard added on 2026-09-10 is
  `atlas.yaml:417-448`, "Refuse a kix that is too old to deploy lab1".
- New CLI, old lib: hard refusal, `StalePin`, "Update the kixpkgs pin to a
  revision at or after the kix.run move"
  (`cli/kix-core/src/legacy_domain/mod.rs:296-300,331-375`).

Two rules follow. The CLI is built from the newest live revision. The oldest
live revision sits at or after the CLI's compatibility floor, today
`66091fb`.

### 2.5 Private packages set the floor, and it keeps rising

`atlas` uses `kix.options.image` and `kix.image.ref`
(`monorepo/src/kix/packages/atlas/default.nix:89,330`), which landed in #89
on 2026-09-09. The shared monitoring module uses `kix.healthCheck`.

The Lithus packages and shared modules are single-versioned and must evaluate
against every live revision. So the oldest revision Lithus can offer is
bounded by its own most recently adopted vocabulary. Every time a private
package takes a new lib feature, the floor moves up under every client.

---

## 3. The tension this doc exists to resolve

### 3.1 Deploy builds from source

`kix deploy` always builds the current tree
(`cli/kix-core/src/eval/build.rs:41`). There is no flag to deploy a previously
built store path (`cli/kix-cli/src/cli.rs:403-461`), and no per-package deploy
filter.

That makes "when does a cluster change" identical to "what does the source say
right now", which is a good property and the reason pinning works at all. It
also means a pending platform change is invisible until something unrelated
triggers a deploy.

### 3.2 The live hazard this already creates

`atlas.yaml` triggers on `flake.nix` but not `flake.lock`
(`monorepo/.github/workflows/atlas.yaml:53-88`). A kixpkgs bump touches only
the lock, so it triggers nothing. The bump then sits on `main` until the next
Atlas push, whose deploy builds from `main` and carries it.

On 2026-09-10 this was harmless only because the bump to `01e827d` was inert,
verified by building `cluster-lab1`, `cluster-stage1` and `cluster-stage2` at both
revisions and comparing store paths. A bump that changed anything would have
shipped under a commit message about image pins.

This needs fixing independently of everything else in this doc. Either add
`flake.lock` to the path filter, which makes every platform bump deploy at
once, or give platform bumps a dedicated workflow. The second is a
prerequisite for the design below, not a consequence of it.

### 3.3 Ring selection reintroduces the same hazard

If a cluster selects a named ring and the ring's revision moves, every cluster
on that ring has a pending change. Under auto-deploy there are two outcomes
and both are bad.

If the ring bump triggers deploys, every client on that ring upgrades at once.
If it does not, the change waits and lands on each client's next unrelated
deploy, which is §3.2 again with more places to hide.

This is the observation that moved the design. Ring selection is fine when
deploys are manual and rare. It fights auto-deploy directly.

---

## 4. Prior art

Web-verified 2026-09-10. Two shapes exist in the field and the difference is
load-bearing.

**Channel subscription** (GKE, OpenShift). The cluster subscribes to a named
channel and the channel's contents move underneath it. GKE promotes a version
rapid to regular to stable once it has accumulated usage and demonstrated
stability. OpenShift describes a channel as how a user declares the minor
version they intend to update to, and maintains an update *graph*: not every
version pair is a legal transition, and reaching the next EUS from 4.6
requires 4.6 to 4.7 to 4.8 serially. Candidate releases may not offer update
paths to later GA releases at all.

**Version classification** (Gardener). Inverted. The version carries a
lifecycle state and an expiry date in a central profile; the cluster names a
version. States are `preview`, `supported`, `deprecated`, `expired`. A shoot
never auto-updates or force-updates *to* a preview version. When a version's
expiry falls before the next maintenance window, Gardener updates to the
highest non-preview version available.

Gardener is the closest structural analogue to Lithus: one operator, many
client clusters, versioned profiles.

**Deferral is always bounded.** GKE requires at least 48 hours of maintenance
availability in a rolling 32 days, counts only contiguous four-hour blocks,
and overrides the window anyway for critical security patches. OVHcloud does
not force the two most recent end-of-support versions but withdraws the SLA,
and force-upgrades the third oldest after 30 days' notice. Linode force-
upgrades non-enterprise clusters at EOL and exempts enterprise. OpenShift EUS
is 18 months and only on Standard or Premium subscriptions.

**Someone pays for old versions.** The field's three answers are: charge for
it (EKS, 14 months standard then 12 months extended at extra cost), force it
after notice, or keep them running without an SLA. There is no fourth.

**Running a stable channel is mostly policy, not branching.** nixpkgs
backports only security-relevant fixes to stable, releases every six months,
and still has no documented policy for when patches stop, an open issue since
2018.

---

## 5. Provisional design

Provisional. Written down to be argued with.

### 5.1 One design, two layers

The mechanism and the policy are separate concerns and were conflated in the
first pass at this.

**Mechanism.** One flake input per live catalogue revision. Bounded at three
or four, not one per client. This is the pattern the monorepo already runs for
Kubernetes itself: `rke2PackagesByMinor` with per-cluster selection via
`lithus.kubernetes.rke2Version` (`monorepo/flake.nix:156-163`,
`platform/nix/lib/rke2-version-module.nix:16-25`, which errors on an
unregistered version).

**Policy.** A profile declaring each revision's classification and expiry,
after Gardener. This is the part that becomes a contractual sentence.

### 5.2 Selection is per client, not per ring

A cluster names a revision, in its own file:

```nix
# client/acme/clusters/acme-prod/kix/cluster.nix
catalogue = "2026-09";
```

Clients on the same revision share an input. Moving a client is a text edit,
not a new input.

The property this buys: **there is never a pending platform change**. A
client's build is fully determined by files in their own directory plus the
revision they name. Promoting a revision changes nobody's build.

### 5.3 The profile

```nix
# platform/kix-catalogue.nix
{
  "2026-06" = { state = "deprecated"; expires = "2026-10-31"; };
  "2026-09" = { state = "supported";  expires = "2027-01-31"; };
  "2026-12" = { state = "preview";    expires = null; };
}
```

Enforced at build time, naturally as a scorecard rule:

- `expired` refuses the build, naming the revision and the date it lapsed.
- `deprecated` warns with days remaining.
- `preview` refuses unless the cluster opts in explicitly.

Expiry is what stops the live-revision count growing without limit. It is the
mechanism, not decoration.

### 5.4 What auto-deploy then looks like

Each client's workflow triggers on their own path:

```yaml
paths:
  - "client/acme/clusters/acme-prod/**"
```

A config change deploys the config change. A platform upgrade is a one-line PR
against that directory, carrying `kix diff acme-prod` as its review artifact.
Adding a revision to `flake.lock` deploys nothing.

The claim this supports: nothing changes on a client's cluster unless a PR
against their directory merges.

### 5.5 Invariants

- A revision is a whole-tree revision. Never a lib version and a catalogue
  version chosen separately (§2.2).
- The CLI is built from the newest live revision; the oldest live revision is
  at or after the CLI compatibility floor (§2.4).
- Private packages and shared modules must evaluate against every live
  revision, enforced by CI. No such job exists today; nothing automated builds
  `cluster-stage1`, `cluster-stage2` or `cluster-lab1`.
- Per-package overrides (`packages // { ... }`) are a reviewed escape hatch
  inside one revision, never the primary model. Holding old packages under a
  new lib is what produced the 9 assertions in §2.2.

### 5.6 Starting point

Two revisions. stage1 and stage2 already act as canaries and take `preview` or the
newest `supported`. lab1 and future clients take `supported`. Hard cap of
three.

---

## 6. Alternatives considered

**Status quo plus discipline.** Deploy each cluster only in its window,
keeping one input. Fails on §3.1: deploy builds from source, so an
already-merged bump ships on the next unrelated trigger. Promises the client
nothing.

**One input per client.** Maximum freedom, and the monorepo already does this
for one RKE2 patch level (`flake.nix:60-74`). Fails by fragmentation past
roughly five clusters: every client becomes its own platform, and the
private-package compatibility matrix goes N-wide.

**Ring selection.** Bounded and simple, and the right answer when deploys are
manual. Rejected as the primary model for §3.3: under auto-deploy it either
upgrades everyone at once or hides a pending change.

**Vendored catalogue snapshots** in the monorepo. Same semantics, worse
provenance: the deploy receipt records flake input revisions
(`cli/kix-cli/src/commands/compliance/receipt.rs:80-83,152-187`) and a
vendored tree has none.

**`--override-input` at the command line** (`cli/README.md:56`). Rejected: the
receipt reads `flake.lock`, so it would record a revision that was not
deployed.

**Decoupling deploy from source**, so a cluster can deploy a previously built
closure. The largest change of any option, needs activation slicing or
per-package deploy (129 §6). Named here because it is what per-client pinning
substitutes for, and the eventual way to need fewer live revisions.

---

## 7. Open questions

1. **Does `nixpkgs` leak the same hole?** kixpkgs is not the only shared
   input; `nixpkgs` feeds `forPkgs`. If a client's rendered output depends on
   it, pinning the catalogue per client while sharing nixpkgs leaves a smaller
   version of the same problem. Settle by building one cluster against two
   nixpkgs revisions and comparing store paths.
2. **Is a legal-transition graph needed?** OpenShift maintains one because
   some upgrades must be traversed serially. `kix migrate` exists and doc 67
   covers stateful migration. If a revision contains a migration, is
   "2026-06 to 2026-12" a legal jump, and should the tool refuse it?
3. **How does a security fix reach every client?** Per-client pinning makes
   this N pull requests. This is 129's pin-coherence resolver, and it is now
   load-bearing rather than a convenience. What opens those PRs?
4. **Who bears the cost of an old revision?** §4 says charge, force, or drop
   the SLA. Which, and does ring access become a paid tier as it is for
   OpenShift EUS and Linode?
5. **How large is a promotion diff in practice?** §2.3 says it can be every
   resource. Measure `kix diff` between two real revisions on lab1 before
   promising anything about review effort.
6. **Do the private packages need their own versioning?** §2.5 makes them the
   floor. A Atlas release and a platform release have nothing to do with each
   other, so a single `catalogue` axis may be the wrong shape.
7. **What does two inputs cost at eval?** Each cluster evaluation reads the
   whole kixpkgs tree (`monorepo/flake.nix:571-573`). Measure before
   committing to four.

---

## 8. Immediate follow-ups, independent of this design

- Fix §3.2. A platform bump must not ship on an unrelated app deploy.
- Add CI that builds every cluster. Today the only automated evaluation is the
  lab1 deploy job itself.
- `legacyPackages.kixClusters` lists lab1 and stage1 only
  (`monorepo/flake.nix:1145-1148`), so `kix list clusters` omits stage2 although
  `cluster-stage2-activation` builds.
- Upstream additions that would make any of this cheaper: a lib version
  constant plus `meta.kix.minVersion` checked in `kix/lib/meta.nix`, so a bad
  combination fails with a diagnosis rather than `attribute 'keys' missing`;
  tagged releases so revisions are names rather than SHAs; `mkFlake` accepting
  `packages` and `kix` overrides.
