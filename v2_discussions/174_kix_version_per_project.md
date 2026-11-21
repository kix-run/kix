# 174: One repository, several Kix versions

**Status:** Draft
**Related:** `archive/169_version_from_flake_lock.md` (the version comes from `flake.lock`), `archive/164_versioning_at_agent_speed.md`, `140_catalogue_versions_and_upgrade_windows.md` (upgrade windows as a managed-service policy), `archive/150_scope_managed_sweep_to_one_cluster.md`
**Supersedes:** `archive/164b_per_cluster_kix_versions.md`

## 1. Problem

A team keeps staging and production in one repository. Both build from one
Kix library, so both upgrade Kix in the same commit. Three things make this
worse than it sounds:

- Minor releases ship several times a week, with no deprecation period and no
  backport line (164 §1). A team that holds production back holds everything
  back.
- A deploy builds from source. Once the upgrade merges, the next unrelated
  production deploy ships it (140 §3.1). The team cannot try a release on
  staging first without freezing production.
- `kix upgrade` builds every cluster before and after, and moves all of them.

An SRE expects the opposite: upgrade staging, watch it, then move production
to the version staging proved. Terraform users get this from one lock file
per root module. Kix users should get it with as little ceremony.

## 2. What the spikes found

Three spikes ran on 21 November 2026 with the released Kix 0.10.0-rc.4 and
0.10.0-rc.5. No code changed.

### 2.1 A repository can already hold several projects

Kix's version belongs to a project, and a project is a folder with a
`flake.nix` and a `flake.lock`. Nothing ties a project to a repository. The
spike used this layout:

```
shared/hello.nix          a module both environments import
envs/staging/flake.nix    pins Kix 0.10.0-rc.5
envs/staging/cluster.nix  imports ../../shared/hello.nix
envs/prod/flake.nix       pins Kix 0.10.0-rc.4
envs/prod/cluster.nix     imports ../../shared/hello.nix
```

All of this worked:

| Step | Result |
|---|---|
| `kix --flake envs/prod build prod` | Kix 0.10.0-rc.4 ran. The shared module read `kix.version` and got `0.10.0-rc.4`. |
| `kix --flake envs/staging build staging` | Kix installed 0.10.0-rc.5 and handed over to it. The same module got `0.10.0-rc.5`. |
| `cd envs/prod && kix build prod` | The same, with no flag. |
| `kix --flake envs/prod upgrade --to 0.10.0-rc.5` | The full review ran (builds, notes). Only `envs/prod/flake.nix` and `envs/prod/flake.lock` changed. |
| `kix list clusters` in a project | 0.2 s. |

Each project also pins its own copy of every other input, such as nixpkgs. A
project's version is therefore a whole release, which is the rule doc 140
measured the need for.

### 2.2 Two library inputs in one flake evaluate, and Kix then runs the wrong version

The second spike put both releases in one `flake.nix` as two inputs and built
one cluster with each library, merging the outputs. Nix evaluated it, and
`kix list clusters` took 0.16 s, so the cost doc 140 worried about is small.

Kix itself does not understand the layout. It chooses which Kix runs from the
input named `kix` and knows nothing about the second input. `kix build prod`
ran Kix 0.10.0-rc.5 on a cluster built by the 0.10.0-rc.4 library, with no
error. Started by hand, Kix 0.10.0-rc.4 refused: "flake.lock pins Kix
0.10.0-rc.5, but this is Kix 0.10.0-rc.4."

### 2.3 Two Kix versions can deploy to one Kubernetes cluster

The third spike deployed `prod` with Kix 0.10.0-rc.4 and `staging` with
0.10.0-rc.5 to one kind cluster, in separate namespaces.

- Both deploys succeeded, and each cluster kept its own Activation record.
- Both clusters ship Kix's two CRDs. The two releases rendered them
  identically, so the second deploy only added its activation to the
  ownership annotation. The CRD definition has not changed since 0.9.0, and
  its `spec` and `status` accept unknown fields, so a newer record is not
  trimmed by an older definition.
- Objects both clusters declare (the two platform records in `kube-system`)
  ended up owned by both activations.
- `kix status --check drift` reported no drift from either side.
- `kix gc prod --full-scan --dry-run` skipped the six objects that belong to
  `staging`.

## 3. Proposal

**The project is the unit that has a Kix version. A repository holds as many
projects as it has groups of clusters that upgrade together.** Clusters stay
inside projects, and a project may hold one cluster or twenty.

This needs no change to how Kix chooses its version, to `mkFlake`, or to
`kix upgrade`. It keeps every rule from docs 140 and 169: a version is a
whole release, `flake.lock` is the only place that names it, and the deploy
receipt records the inputs that were deployed.

What Kix lacks is the knowledge that projects can be siblings. The work is in
four small parts.

### 3.1 Document and test the layout

- A how-to page, "Upgrade environments separately", with the layout from
  §2.1, the upgrade order from §4, and the steps to split an existing
  project (§6).
- A test that builds two sibling projects on two library versions with a
  shared module, so a later change cannot break the layout unnoticed.
- `kix init` in a subfolder of a repository that already holds a project.
  This is untested.
- A clear message when Kix runs in a folder with no `flake.nix`. Today the
  user gets Nix's own error. The message should name the projects found
  below the folder and show the `--flake` form.

### 3.2 An overview of the projects in a repository

`kix list projects` prints one line for each project in the repository: its
folder, the Kix it pins, and how old that release is. It reads only
`flake.lock` files, so it needs no evaluation and returns at once. With
`-o json` it gives CI the list of projects to build when shared code changes.

```
$ kix list projects
PROJECT        KIX       RELEASED
envs/staging   0.14.2    3 days ago
envs/prod      0.12.3    5 weeks ago
```

How Kix finds the projects is open (§8, question 1).

### 3.3 Move one project to the version another has proved

```
kix --flake envs/prod upgrade --like envs/staging
```

`--like` reads the version the other project pins and behaves as
`--to <that version>`. It saves the SRE from copying a version number and
makes the intent readable in a pull request or a CI job.

### 3.4 Warn about releases that are getting old

A release reads cluster state written in the last six months. A project left
behind for longer cannot upgrade in one step. `kix list projects` and
`kix doctor` should mark a project whose release is close to that limit.
This also keeps the number of versions in one repository small without a
separate policy setting.

## 4. A week in the life

| The SRE wants to | Does | Works today |
|---|---|---|
| Try a new Kix on staging | `kix --flake envs/staging upgrade`, review, merge, deploy | Yes |
| Keep deploying production meanwhile | `kix --flake envs/prod deploy prod` | Yes. Production's lock did not move. |
| Move production to what staging runs | `kix --flake envs/prod upgrade --like envs/staging` | With `--to <version>` |
| See which environment is on what | `kix list projects` | No |
| Change a shared module | Edit `shared/`, and CI runs `kix check` in every project | Yes, with the projects listed in the CI file |
| Ship a fix to production without the new Kix | Commit, deploy | Yes |
| Take a security fix everywhere | Upgrade each project, staging first | Yes |
| Hold one client back for a change freeze | Give that client its own project | Yes |

Shared modules and private packages must build with every Kix version in the
repository. That is the standing cost of running more than one version, and
it is the same in every design. CI catches a break because it builds every
project. A module that must differ can read `kix.version`, which the spike
confirmed.

### 4.1 Where the cost of two versions sits

Once clusters upgrade at different times, two versions exist at once and
something has to work with both. That cost can sit in four places:

1. In time. Everything upgrades together, and production waits. This is
   today.
2. In Kix. Each cluster declares a compatibility level, and the library
   keeps old behaviour behind it for some months, as NixOS does with
   `stateVersion`. Doc 164 gave this up for speed.
3. In the project's shared code. It must work with every Kix version in the
   repository.
4. In the project's history. Each environment pins its own copy of the
   shared code, and a fix is carried to each line.

Decided on 21 November 2026: the cost sits in the shared code (3) for now.
It grows with how long the versions stay apart, and for staging followed by
production that is a few days. A project that must stay behind for months
can pin an older copy of the shared code (4), which separate projects allow.

### 4.2 Sharing facts between clusters

A cluster in one project should not import a cluster definition from
another. It would evaluate that definition with its own Kix library, which
may fail, and which shows what its version would build and may differ from
what the other cluster deploys. Two ways work across versions:

- A plain data file that both clusters import, for values such as domains,
  address ranges, and endpoint names.
- The interface file a hosting cluster writes for a consumer (doc 156,
  `clusters/test-consumers/`). It records what the hosting cluster built.

## 5. Two Kix versions on one Kubernetes cluster

This is allowed today, and the spike in §2.3 found no fault. It is the same
situation as two repositories deploying to one Kubernetes cluster, which Kix
has supported since doc 150. Three things remain:

1. **An object both Kix clusters declare.** When the two builds render it
   differently, each deploy overwrites the other and nothing warns
   (`ROADMAP.md`, "Two Kix clusters that render one shared object
   differently"). Two Kix versions make a difference far more likely,
   because the same package may pin another version of its software. This
   design raises the priority of that item. The deploy already knows the
   hash it applies and which activations own the live object, so `kix plan`
   can say "this object also belongs to Kix cluster `staging`, and this
   deploy changes it."
2. **Kix's own CRDs.** Both clusters ship them, and they are identical
   today. If a release ever changes them, an older Kix on the same
   Kubernetes cluster would put the old definition back on its next deploy.
   The CRDs carry no Kix version, so nothing can tell which is newer. That
   release would need its change record marked `state = true`, and a rule
   that Kix never applies its CRDs over ones a newer Kix applied.
3. **The operator.** One operator may serve Kix clusters deployed by
   different versions. Whether it must be the newest of them is not
   examined here (§8, question 4).

## 6. Splitting an existing project

1. Make a folder for each group of clusters that should upgrade together.
2. Move each cluster's files there. Paths to shared modules become relative
   paths out of the folder.
3. Give each folder a `flake.nix` that lists its clusters, and a copy of the
   old `flake.lock`. Every project then starts on the pins the old project
   had.
4. Run `kix plan` for each cluster. It should show no changes. A cluster
   keeps its name, and its records in Kubernetes are found by name, so the
   deploy history should carry over. Both points need a test on kind before
   the how-to page promises them.

A repository whose root `flake.nix` has other outputs keeps it. The projects
sit below it and do not need to be its inputs.

## 7. Alternatives considered

**Per-cluster versions inside one flake** (the 164b sketch, and spike 2). One
`flake.nix` declares an input for each Kix version in use, and each cluster
names one. It keeps a single flake, which suits a repository with dozens of
clusters. It was not chosen because of what it adds:

- Kix must find the cluster in the command before it chooses a version, and
  must read which input the cluster uses without evaluating anything. That
  needs a table in `kix.toml`, a second place that takes part in naming a
  version. Doc 169 removed exactly that.
- `mkFlake` of one release must build a cluster with the library of another,
  and each Kix must accept a project that holds libraries of other versions.
  That is a contract between releases that every later release has to keep.
  Kix has none today.
- `kix upgrade` must add, move, and remove inputs in `flake.nix`.
- The other inputs are shared between versions unless each cluster also
  chooses its own nixpkgs. A version stops being a whole release.

Sibling projects give the same result with none of this, and a project can
hold many clusters, so the repository with dozens of clusters needs a few
projects, one for each version it runs.

**A lock file of Kix's own** that maps each cluster to a version and a hash,
read by Kix and by `mkFlake`. Rejected for the first two reasons above, and
because inputs that `flake.lock` does not record surprise Nix users and are
missing from the deploy receipt.

**A branch for each environment.** Rejected. Shared modules drift apart, and
every fix becomes a merge between branches.

**Deploy only in a window, with one version.** Rejected in 140 §6: a merged
upgrade ships with the next unrelated deploy.

## 8. Open questions

1. **How does Kix find the projects in a repository?** Either a list in a
   `kix.toml` at the repository root (`[workspace] projects = ["envs/*"]`),
   or every tracked `flake.lock` whose flake has an input named `kix`. The
   list is predictable and costs one file. The search needs no setup, and
   would also find test fixtures. Leaning to the list.
2. **Should `kix deploy prod` work from the repository root?** Kix would
   have to learn which project defines `prod`, which means evaluating each
   project (0.2 s each when warm) or keeping a cache. `--flake` and `cd`
   work today, and CI always knows the folder. Leaning to leave it until
   someone asks.
3. **Does a cluster keep its history when it moves between projects?** §6
   assumes so. Test it.
4. **Which Kix must the operator be** when it serves clusters deployed by
   different versions?
5. **What does doc 140 keep?** Its mechanism (one input per live revision)
   is replaced by projects. Its policy (classifying revisions, expiry as a
   contractual promise, who pays for an old revision) is untouched and is a
   managed-service question. Doc 140 should be cut down to that.
6. **Does `kix upgrade` show too much for a small project?** The upgrade of
   a one-package project listed 39 notes, most about packages it does not
   use. Doc 164 chose not to filter. With more, smaller projects, the choice
   may be worth another look.

7. **Is the interface file's format promised between releases?** Two
   projects on different versions would exchange it (§4.2). Check whether
   it carries a format version.
8. **Does importing files from outside the project folder hold?** The spike
   imported `../../shared` because Kix copies the whole Git repository. Find
   what Nix promises here, and cover it with the test in §3.1.

## 9. Order of work

1. The kind tests from §6 and question 3, and `kix init` in a subfolder.
2. The how-to page and the two-project test (§3.1). After this step the
   feature exists for users.
3. The message for a folder with no `flake.nix` (§3.1).
4. `kix list projects` and the age mark (§3.2, §3.4).
5. `kix upgrade --like` (§3.3).
6. The warning for a shared object that two Kix clusters render differently
   (§5, item 1).
