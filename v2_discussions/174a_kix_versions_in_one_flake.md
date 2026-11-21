# 174a: Several Kix versions in one flake

**Status:** Accepted, a variant of 174. Implemented in kix#288, not merged yet
**Related:** `174_kix_version_per_project.md` (the problem, the first three spikes, and the separate-projects design), `archive/169_version_from_flake_lock.md`, `interesting_thoughts/169b_bundled_kix_library.md`

Doc 174 gives each group of clusters its own project folder. This variant
keeps one `flake.nix` and one `flake.lock` at the repository root, which is
the usual Nix layout. Doc 174 §7 turned down the first one-flake design
because one release had to build clusters with another release's library.
This design avoids that.

## 1. The idea

The flake's outputs use one input, `kix`, as they do today. A project that
holds some clusters back declares a second input for the older version.
Nothing in the outputs reads it. When Kix works on a held-back cluster, it
runs the older Kix and evaluates the flake with the `kix` input swapped for
the second one. Each Kix therefore evaluates the whole flake with its own
library, and no release meets another's.

```nix
# flake.nix
{
  inputs.kix.url        = "github:kix-run/kix/v0.14.2";
  inputs.kix-stable.url = "github:kix-run/kix/v0.12.3";   # held back

  outputs = inputs: inputs.kix.lib.mkFlake {
    inherit inputs;
    clusters.staging = ./clusters/staging.nix;
    clusters.prod    = ./clusters/prod.nix;
  };
}
```

```toml
# kix.toml
[versions]
kix        = ["staging"]
kix-stable = ["prod"]
```

`[versions]` names the Kix versions in the project. Each key is
the name of an input in `flake.nix`, written the same way in both files, so
a reader can match them by eye. Once the table exists it lists every cluster, and a
cluster it leaves out is an error, so a new cluster cannot land on the
newest version unnoticed. A project with no table has one version, as today. `flake.lock`
still holds every version and is the only place that does.

The input `kix` pins the newest release in the project. A cluster that is
held back names another input. Kix refuses a project where another input
pins a newer release than `kix`, and names both. An input that is a folder
or a branch has no release and is exempt (§5a). `kix.toml` says
which clusters use which input, and holds no version number.

## 2. Spike

Run on 21 November 2026 with the released Kix 0.10.0-rc.4 and 0.10.0-rc.5
and the `flake.nix` above (no `kix.toml` table, since no release reads one).

| Step | Result |
|---|---|
| `kix build staging` | Kix 0.10.0-rc.5 and its library built it. |
| Kix 0.10.0-rc.4 with `--override-input kix <the locked kix-stable>` on `prod` | Kix 0.10.0-rc.4 and its library built it, in 0.22 s. |
| `flake.lock` afterwards | Unchanged. |

The swapped-in reference came from the `kix-stable` entry of `flake.lock`
with `jq`, so choosing it needs no evaluation. An input that follows the
library, such as `nixpkgs.follows = "kix/nixpkgs"`, follows the swap, so a
named version is still a whole release.

## 3. What Kix would do

1. **Choose the version.** Kix finds the cluster named in the command,
   looks it up in `[versions]`, and reads the release tag of its input from
   `flake.lock`. It then runs that Kix, as it does today for the one input.
   A command that names no cluster runs in the Kix of the input `kix`.
2. **Evaluate.** The chosen Kix evaluates the flake with `kix` swapped for
   the locked input of that cluster.
3. **Refuse the wrong library.** `mkFlake` already reads `kix.toml`. It
   compares the library it runs from with the input each cluster names,
   and a cluster that names another input fails with an error that gives
   the input and its version. Plain `nix build` and `nix flake check` use the input
   `kix` for everything, so without this they would build a held-back
   cluster with the wrong version and say nothing.
4. **Upgrade with one command.** `kix upgrade` takes an optional name
   and keeps `--to`. It gains no new command and no new flag.

   | Command | What moves |
   |---|---|
   | `kix upgrade` | The input `kix`, to the newest release. |
   | `kix upgrade kix-stable` | The input `kix-stable`, to the release `kix` pins. `--to` names an older one. |
   | `kix upgrade prod --to kix` | The cluster `prod`, to the version the input `kix` pins. |

   A name is an input or a cluster, so a cluster may not have the name of an
   input. Naming an input changes its tag in `flake.nix`, locks that one
   input again, and reviews the clusters that use it. Naming a cluster
   reviews that cluster between its old and new version, then edits
   `[versions]`. A person may still edit `[versions]` directly, and
   `kix plan` shows what changes.
5. **Show it.** `kix list clusters` gains a column for each cluster's Kix
   version, which is the overview doc 174 needed a new command for.

No release evaluates another release's library. What releases share is the
`[versions]` table and the input names, read by each Kix on its own.

## 4. Compared with separate projects (174)

| | One flake, several versions | Separate projects |
|---|---|---|
| Layout | One `flake.nix`, one lock: the usual Nix layout | A flake for each group, which is less common |
| Works today | No | Yes |
| Change to Kix | Version choice, evaluation, the library check, `mkFlake`, `kix upgrade`, the deploy receipt | Docs, one message, one listing command |
| New concept | A `[versions]` table in `kix.toml` | None |
| Overview | `kix list clusters` | `kix list projects` (new) |
| Move a cluster to another version | Edit one line of `kix.toml` | Move its files, or upgrade its project |
| Shared code | Files in the same flake | Relative paths out of the project folder, which needs a guarantee from Nix (174 §8, question 8) |
| Other inputs | Shared by all versions unless they follow the library | Pinned by each project |
| Plain `nix` on a held-back cluster | An error that gives the override to pass | Works |
| Hold a client back for months with frozen shared code | Hard: every cluster reads the same files | Possible: pin an older copy |

Separate projects stay possible whichever is chosen, because they need
nothing from Kix.

## 5. Costs and risks

- **Finding the cluster before the command is parsed.** Kix chooses its
  version before it reads its arguments in full, because the chosen Kix may
  take other arguments. §5b gives the rule. A wrong guess is safe: the
  chosen Kix parses the command properly, finds that its version is not the
  cluster's, and stops.
- **Two files take part.** `kix.toml` assigns and `flake.lock` pins. They
  cannot disagree about a version, because only the lock holds one. A table
  entry that names a missing input, or a missing cluster, is an error.
- **Moving a cluster to another version is an upgrade with no review.** It is a
  one-line edit, so `kix upgrade` never sees it. The deploy still enforces
  required stops, and `kix plan` shows the changes, but the upgrade notes
  are not shown.
- **The `nix` builder.** A project that builds with plain Nix must pass the
  override itself for held-back clusters. The refusal in §3 step 3 tells it
  how.

- **Every version reads the same `flake.nix` and `kix.toml`.** A setting
  that arrives in a newer release would break the held-back clusters,
  because Kix refuses a `kix.toml` setting it does not know
  (`cli/kix-core/src/project.rs`) and `mkFlake` refuses an argument it does
  not know. Decided on 21 November 2026: the Kix of the input `kix` checks
  both files in full, as today, because it is the newest and knows every
  setting. A Kix that runs for another input skips what it does not know.
  A typing mistake is still caught by every command on a cluster that uses
  `kix`, by `kix check`, and by `kix doctor`, which already fails on an
  invalid `kix.toml`. A known setting with a value the older Kix does not
  know is not covered, and needs a rule of its own.

## 5a. A version that is not a release

Today a project uses a development library when its `kix` input is a local
folder or a branch, when a command passes `--override-input kix`, or when
`kix.toml` sets `library = "self"`. Kix then runs the version the person
started and compares nothing. With several inputs, the rule applies to each
input on its own:

- **An input that is a folder or a branch.** Its clusters run in the Kix the
  person started, with a note, as today. Clusters on other inputs are not
  affected. A maintainer can point `kix-next` at a checkout, put staging on
  it, and leave production on a release.
- **`--override-input` on a command.** It applies to a cluster when it names
  that cluster's input, so `--override-input kix-stable <url>` replaces the
  library for the clusters on `kix-stable`. Kix warns when a command
  overrides `kix` and the cluster uses another input, because the override
  does nothing there. To try one library on every cluster, override every
  input.
- **`library = "self"`.** The project's own flake provides the library, so
  it has one version by construction. Kix refuses a `[versions]` table in
  such a project.
- **`kix upgrade` on a development input.** As today, it pins the input to
  a release without a review, because there is no earlier release to
  compare with.
- **The refusal in the library** (§3, step 3) compares the library in use
  with the input the cluster names. Kix swaps in that input after applying
  any override of it, so the two match and the refusal stays quiet.

## 5b. Finding the cluster in a command

A review of every command on 21 November 2026
(`cli/kix-cli/tests/snapshots/cli_surface.snap`, `cli/kix-cli/src/cli.rs`)
found:

- Every command that acts on a cluster takes exactly one, and takes it as
  the first bare word after the command. `list`, `migrate`, and
  `compliance` have one more command word first (`list resources prod`).
- No command takes two clusters.
- Looking for any word that matches a cluster name is not reliable.
  `kix export staging --out prod` and `kix deploy --plan prod staging`
  would both choose the version of `prod`, because Kix does not know before
  parsing that `--out` and `--plan` take a value.

The rule is therefore: the cluster is the first bare word after the command
words. To find it, the code that chooses the version needs a list of the
flags of each command that take a value, as it has today for the global
flags. A test keeps that list in step with the snapshot of the command
line. About fifty flags take a value today.

The implementation keeps no lists by hand. Before it parses, Kix builds
the command definition (`cli::command()`) and reads from it which flags take
a value, which commands have a second command word, and which commands take
a cluster: the ones whose first positional argument is named `cluster`. A
new command or flag is then covered when it is defined. Two checks keep the
definition honest. `Command::cluster_name` matches every command with no
catch-all arm, so a new command does not compile until it says whether it
has a cluster. A test checks that a command returns a cluster there exactly
when its first positional argument is named `cluster`. The prototype uses
lists and a test instead.

Commands that name no cluster:

| Command | What it needs | Runs in |
|---|---|---|
| `kix list clusters`, `kix list packages` with no cluster | One library's view of the project | The Kix of the input `kix` |
| `kix status` with no cluster | Reads every deployed cluster from Kubernetes, and evaluates nothing | The Kix of the input `kix` |
| `kix pin`, `kix doctor` | No cluster and no evaluation | The Kix of the input `kix` |
| `kix upgrade` | Builds clusters before and after | Already runs each build in the Kix of that version |

`kix status` and `kix snapshot` take the name on the cluster's deploy
records. That name differs from the cluster's key in `flake.nix` when the
definition sets its own `name`, and `[versions]` is keyed by the key in
`flake.nix`. Neither command evaluates the project, so the library version
does not matter to them. A name the table does not hold runs in the Kix of
the input `kix`.

Proposed: `kix status` and `kix snapshot` take the key in `flake.nix` as
well, as `kix rollback` and `kix history` do (`cluster_identity` in
`cli/kix-cli/src/commands/mod.rs`). They look for deploy records under the
word given, and evaluate the project to find the name only when there are
none. `kix status` keeps working outside a project.

## 6. Other one-flake designs

**One library builds a cluster with another** (164b). Rejected in 174 §7.

**Ship the library inside the Kix release** (169b), with a version for each
cluster in `kix.toml` and no library input at all. It gives the simplest
project file. It changes far more, and it reverses doc 169 a week after it
shipped. This design does not rule it out later.

**An input for each cluster, found by its name** (`kix-prod` for the cluster
`prod`), with no table. It needs no `kix.toml` entry, but twenty clusters on
one old version need twenty inputs.

## 7. Smaller points, with proposed answers

Proposed on 21 November 2026. None needs code that converts an existing
project.

**Setting up the second version the first time.** The how-to page gives
two edits: add `inputs.kix-stable.url` with the same URL as `kix`, and
write the `[versions]` table. `kix upgrade` does not write either. The
errors carry the rest: a table that names an input `flake.nix` lacks gives
the line to add, and a table that leaves out a cluster lists the clusters
it must hold. The prototype must check what Kix does between the edit and
the first lock of the new input.

**A cluster's key and its `name` stay separate.** Making them one would
remove the lookup in §5b, but this repository relies on the difference:
`gateway-swap-envoy` and `gateway-swap-traefik` are two definitions of the
one deployed cluster `test-gateway-swap`, and the swap tests deploy one
over the other. The key is what a person types and what `[versions]`
lists. The `name` is what Kubernetes records carry. `kix status` and
`kix snapshot` accept the key as well (§5b).

**A known setting with a value the held-back Kix does not know stays an
error.** `kix.toml` has three settings today: `builder`, `library`, and
`[upgrade] min-age`. An unknown setting can be skipped because the older
Kix has no behaviour for it. A known setting changes how that Kix builds,
so it cannot guess. The error names the cluster's input and its version,
and says the value needs a newer Kix. The project uses the new value once
every cluster has moved.

## 8. Order of work

1. A prototype on a branch of the version choice (§5b), the swap during
   evaluation, and the refusal in the library (§3, step 3), tested with two
   versions as in §2.
2. The implementation, with its tests, change records, and the reference
   pages it touches.
3. Last, a pass over all the existing documentation by Antigravity
   (`agy`, Gemini 4 Carbon). It reads every page under
   `docs/src/content/docs/` against the choices in this doc and updates
   what they change: one project with one version is no longer the only
   layout, `kix.toml` has a `[versions]` table, `kix upgrade` takes a name,
   and `kix status` accepts a cluster's key. This is wider than
   `scripts/copy-pass`, which only edits text a branch changed. Check every
   claim it adds against the code.

## 9. Prototype

Built on 21 November 2026 on the branch `prototype/kix-versions-one-flake`.
It covers step 1 of §8 and nothing else.

**What it has**

- `cli/kix-core/src/versions.rs`: reads `[versions]`, finds a cluster's
  input, checks that every input exists in `flake.lock` and that `kix` pins
  the newest release, and writes the flake reference of a locked input.
- `cli/kix-cli/src/select.rs`: finds the cluster before parsing (§5b) and
  chooses the Kix of its input. A test walks every command and fails when a
  flag that takes a value is missing from the list, or when a flag takes a
  value in one command and none in another.
- `GlobalArgs::input_overrides` (`cli/kix-cli/src/cli.rs`): adds the pair
  that replaces `kix` with the cluster's input. Every evaluation reads its
  overrides from there, so one change covers them all.
- `kix/lib/mkFlake.nix`: refuses a cluster evaluated with the library of
  another input, and a cluster the table leaves out.

**What the test showed.** Two builds of the prototype, 0.10.0-proto.1 and
0.10.0-proto.2, each with a tagged library, and a project with `staging`
on `kix` and `prod` on `kix-stable`:

| Step | Result |
|---|---|
| `kix build staging` | Kix proto.2 and its library. |
| `kix build prod`, started with proto.2 | Handed over to proto.1, which built with its library. 0.38 s. |
| `kix build prod` with proto.1 not installed | "This project uses Kix 0.10.0-proto.1 (flake.lock), and Kix 0.10.0-proto.1 is not installed." |
| Kix proto.2 forced onto `prod` | "flake.lock pins Kix 0.10.0-proto.1, but this is Kix 0.10.0-proto.2." |
| `kix build dev`, a cluster the table leaves out | "kix.toml [versions] does not list the cluster `dev`. Add it to one of: `kix`, `kix-stable`." |
| `kix export staging --out prod` | Chose `staging`. |
| Plain `nix eval` of `prod` | The library's refusal, with the fix. |
| Plain `nix eval` of `staging` | Worked. |
| `kix-stable` pinned newer than `kix` | Refused, naming both inputs and versions. |
| `flake.lock` after all of it | Unchanged. |

The unit tests of `kix-core` (283) and of the `kix` program (214) pass.

**What it found**

- No flag takes a value in one command and none in another, so the scan
  can step over a value by the flag's name alone. Forty-seven flags take a
  value.
- A command that acts on no cluster (`kix pin`, `kix self`, `kix doctor`,
  `kix upgrade`) needs to be on a list, or its first word is taken for a
  cluster.
- An input that `flake.nix` declares and `flake.lock` does not hold yet
  gets a wrong message: "flake.nix has no input named kix" for a cluster on
  the new input, and "Add `inputs.kix-old.url` to flake.nix" for the
  others. The implementation should lock the new input, or say to.
- The library cannot check a cluster on `kix`, because the replaced input
  is not visible to it (§3, step 3).

**What it leaves out**

- `kix upgrade` with a name (§3, step 4).
- A held-back Kix skipping settings it does not know (§5).
- `kix list clusters` showing each version, and `kix status` and
  `kix snapshot` accepting a cluster's key.
- The deploy receipt naming the input a cluster used.
- An input that is a folder or a branch (§5a), which the code handles and
  no test covers.
- Integration tests, the change record, the reference pages, and
  formatting of `mkFlake.nix`.

## 10. Implementation

Built on 21 November 2026 in kix#288, from the prototype. What it settled
beyond the sections above:

- **A second input on the same url.** `kix upgrade` used to stop when two
  inputs named one repository at one tag, which is exactly the state after
  the first setup step. Kix now reads which input a url belongs to
  (`owner_of` in `cli/kix-core/src/pin_library.rs`) and changes only that
  one.
- **A cluster that fails on its new input stays there.** The run saves its
  state as an upgrade of an input does, so the person fixes the cluster on
  the new version and the same command resumes. Putting the cluster back
  would leave no way to fix a cluster that needs the new library.
- **A cluster only moves to a newer version**, and not past a release that
  must be deployed first.
- **An input with no clusters is only pinned.** This is the first upgrade
  after every cluster is held back.
- **Held back means older than `kix`.** The CLI compares the running Kix
  with the release `kix` pins. The library compares its own version with
  the tag `flake.lock` records for `kix`. Neither needs to know the cluster.
- **A new input is locked with `kix upgrade <input>`**, and every other
  command says so.
- **An older release cannot be one of the versions.** A Kix from before
  this change refuses the `versions` key. No floor is written into the
  code, because the release that ships this is not numbered yet.

Not tested against a live cluster: the `builder.kixInput` field of the
deploy receipt, and `kix status` and `kix snapshot` with a cluster's key.
The scratch kind cluster of spike 3 was gone.
