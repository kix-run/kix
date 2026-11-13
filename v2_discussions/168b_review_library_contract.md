**Status:** Review input to doc 168 (2026-11-13). Doc 168 records the decisions; where they differ, 168 wins.

# Proposal: the boundary between Kix and the Kix library (0.10.0)

Two parts. Part 1 is how the library reports an error to Kix. Part 2 is how
Kix moves the library a project pins. Paths are relative to the repository
root. Nothing here has been built. Two details that need a test before
anyone relies on them are marked "verify".

---

## Part 1. Errors from the library

### Current behaviour

Kix runs `nix eval --show-trace` and gets back one block of text on stderr.
`shorten_trace` (`cli/kix-core/src/eval/nix.rs:532`) decides what to show by
matching that text:

| Rule | Where | What it matches |
|---|---|---|
| The message carries a change id | `names_its_fix`, `nix.rs:635` | `[K` plus four digits plus `]` anywhere in the message |
| Unknown option | `nix.rs:639` | starts with ``error: The option ` `` and contains `' does not exist.` (nixpkgs wording) |
| The message gives a fix | `nix.rs:642` | any line that starts with `Fix: ` |
| The cluster's problem list | `nix.rs:646` | starts with `error: cluster '` and contains ` problem(s):` |
| The frame is in the library | `in_library`, `nix.rs:611` | the path contains `«github:NixOS/nixpkgs` or `/kix/lib/` |
| A Kix package raised it | `in_kix_level_folder`, `nix.rs:621` | the path contains `/kix/{packages,contracts,modules}/{stable,experimental}/` |

`missing_attribute` (`nix.rs:105`), `system_eval_error` (`nix.rs:396`), and the
Helm placeholder scan also match text. They are about Nix and Helm, and
Part 1 leaves them alone.

The library raises errors in these ways (counts leave out `kix/lib/tests/`):

| Way | Count | Notes |
|---|---|---|
| Bare `throw` in `kix/lib/` | about 250 | `scope/validators.nix` 22, `core/resource.nix` 19, `scope/builders.nix` 18, `eval/import.nix` 17, `helm.nix` 15, `vocab/pins.nix` 14 |
| Bare `throw` in packages | 239 | 51 stable, 188 experimental. Each builds its own `"${who}: "` prefix. |
| Bare `throw` in contracts and modules | 10 | `vocab/contract.nix:85,109,128` build the text for every contract |
| `assertions = [ { assertion; message; } ]` | about 204 entries | Collected per instance (`meta.nix:366`), then raised as one `throw` at `meta.nix:413` |
| A second problem list | 1 | `packages/experimental/cluster-issuer/default.nix:439` copies the `problem(s):` wording |
| Messages with a `[Kxxxx]` id | 16 sites, 10 ids | typed by hand into the string |
| Messages with a `Fix: ` line | 53 lines | mostly `eval/resolve.nix` and `eval/auto.nix` |
| `assert` | 11 | Nix prints the failed expression, with no message |
| nixpkgs module system | not ours | unknown option, wrong type, option used and not defined, conflicting definitions |
| Nix itself | not ours | missing attribute, type error, infinite recursion |

There is no shared helper. Each message's prefix, id, and fix are
conventions that the Rust code has to rediscover.

### Proposed design

**One rule: an error written for a person carries a marked JSON line. Kix
reads that line and nothing else.**

1. A new file `kix/lib/core/error.nix` holds the only code that builds a
   user-facing error:

   ```nix
   kix.fail {
     message  = "the `password` option was removed.";   # required
     fix      = "Set deps.password = ref.shop.db-login;"; # optional, may span lines
     id       = "K9503";                                  # optional change record id
     instance = "shop/db";                                # optional, namespace/name
     package  = "cnpg-database";                          # optional
     option   = "instances.shop.db.password";             # optional, the path to edit
   }
   ```

   `scope.fail` is the same call with `instance` and `package` filled in, so
   a package stops building its own `who` prefix. `scope.fail "text"` is
   short for `{ message = "text"; }`.

2. An assertion keeps its shape and gains the same optional fields:
   `{ assertion; message; fix ? null; id ? null; option ? null; }`. The
   collector at `meta.nix:381` sets `instance` as a field and stops gluing
   `[name] ` onto the message. The cluster's problem list at `meta.nix:413`
   becomes one call that carries every failed assertion.

3. What the helper throws is plain text for a person, followed by one last
   line for Kix:

   ```
   error: cluster 'prod' has 2 problems:
            - shop/db (cnpg-database) [K9503]: the `password` option was removed.
              Fix: Set deps.password = ref.shop.db-login;
            - shop/web: dependency 'backend' is missing.
          kix-error/1 {"errors":[{"id":"K9503","instance":"shop/db",...},{...}]}
   ```

   The text above the marker is for someone who runs Nix directly (the `nix`
   builder, `nix flake check`). Kix ignores it. Kix finds `kix-error/1 ` at
   the start of a line in the final `error:` block of stderr, parses the
   rest of that line as JSON, and renders from the fields. I checked with
   Nix 2.34.9 that a thrown string keeps a JSON line whole, quotes and
   escaped newlines included. The marker must be read only from the final
   block, because trace frames quote source lines and the helper's own
   source contains the marker text.

4. Kix sorts every failed evaluation into three cases, in this order:

   | Case | How Kix knows | What Kix shows |
   |---|---|---|
   | Written for the user | the `kix-error/1` line is present | Each error from its fields: id, instance, package, message, fix. No stack trace. `-o json` gets the same list. |
   | Raised in the project's own files | no marker, and the frame nearest the error is in the project | Nix's message and up to three project frames, as today |
   | Raised anywhere else | no marker, and the nearest frame is outside the project | Nix's message alone, plus "N stack frames hidden, run with -v" |

   The last two cases cover what the library did not write. A missing
   attribute or a type error in a cluster definition has its nearest frame
   in the project, so the user sees where. An unknown option or a wrong
   type is raised inside nixpkgs, and its message already names the option
   and the file. A bare `throw` in a package that has not moved to
   `scope.fail` also stands alone, as the folder rule shows it today.

5. "In the project" is a fact the library publishes. `mkFlake.nix` already
   has `inputs.self` (it reads `kix.toml` from it). It adds
   `kixLibrary.projectRoot = toString inputs.self`. Kix already evaluates
   `kixLibrary` once per run (`library_facts`, `nix.rs:482`). A frame is the
   project's when its path starts with that root or with the local project
   directory. Kix then knows no folder name inside the library. *Verify:*
   which path form the Nix in the Kix runtime prints for a file of the root
   flake. The fixtures show `/nix/store/x-source/...` and `«github:...»/...`.

6. A unit test in `kix/lib/tests/` fails when a file under `kix/packages/`
   or `kix/contracts/` contains a bare `throw`, so the contract stays true.

### Changes to `nix.rs`

- Delete `names_its_fix`, `in_library`, `in_kix_level_folder`, and five of
  their tests (about 120 lines).
- Add `eval/library_error.rs`: the `LibraryError` struct (unknown fields
  skipped), `parse(stderr)`, and the renderer. About 150 lines with tests.
- `KixEvalError` gains `Library(Vec<LibraryError>)`. `eval_with_helm`
  (`nix.rs:278-305`) tries `parse` before `brief()`.
- `shorten_trace` keeps only the frame logic, takes the project root, and
  halves in size. `LibraryFacts` (`nix.rs:472`) gains `project_root`.

### Throw sites that change

| Step | Sites | When |
|---|---|---|
| The helper, `scope.fail`, the assertion fields, the two problem lists | 4 | 0.10.0 |
| `vocab/contract.nix` (covers every contract) | 3 | 0.10.0 |
| The 16 sites with a `[K` id | 16 | 0.10.0 |
| The sites with a `Fix: ` line (53 lines) | about 40 | 0.10.0 |
| Package throws to `scope.fail` | 239 | 0.10.0 or 0.10.x |
| The other library throws | about 190 | 0.10.x, file by file |
| The 11 `assert`s | 11 | 0.10.x, each gets a message or is confirmed internal |

About 60 sites must change before the text rules can go. The other 440 can
move later and lose nothing meanwhile, because case 3 shows them as today.
The package throws are mechanical: drop the `who` prefix and call
`scope.fail`. Tests that compare message text need updating (not counted).

### Alternatives rejected

- **Return errors as data and never throw.** Nix can catch a throw
  (`builtins.tryEval`) but cannot read its message. Only the assertion lists
  could travel as data, which leaves two channels to keep in step.
- **A plain-text prefix such as `kix: ` on every message.** The id, the
  instance, and the fix would still be parsed out of prose.
- **Throw only JSON.** A person who runs Nix directly gets an unreadable line.
- **Write the errors to a file in Kix's local store and throw its path.** It
  adds a store write and a file read to the failure path, and the `remote`
  builder would have to carry the file back.
- **Recognise nixpkgs' module errors by their wording.** Case 3 already
  shows them correctly, and nixpkgs can reword them at any time.

### Migration and breaking impact

- Nothing breaks for a user. `kix.fail` and `scope.fail` are additions. A
  third-party package that still uses `throw` keeps working (case 3).
- Message text changes, which `CLAUDE.md` does not list as stable. One
  `changed` record covers it. `-o json` can gain an `errors` list.
- `scripts/change-kind.py` still finds each change id in the output.
- Update `kix/lib/architecture.md`, `package-anatomy.mdx`, and the
  `package-authoring` and `package-review` skills (no bare `throw`).

### Effort

Medium. The contract and the 60 sites are about two days. The 239 package
sites are a mechanical batch for parallel agents and one review.

Noticed and not designed: `shorten_trace` drops every `trace:` line
(`nix.rs:535`), so the library's warnings disappear whenever an evaluation
fails. Warnings could use the same record shape later.

---

## Part 2. Moving the library a project pins

### Current behaviour

`update_to` (`cli/kix-core/src/library.rs:502`) moves the library input to
the tag of the running Kix. It reads three sources and reconciles them:

1. `flake.lock` on disk (`library.rs:511`). It finds "the library" by
   walking every input, nested ones included, and matching the URL against
   `github:kix-run/kix`, or the input name against `kixpkgs` or `kix`, or
   the repository name against either (`classify`, `library.rs:292-308`).
2. If step 1 says a person must act, the lock Nix computes from `flake.nix`
   (`current_lock`, `library.rs:529` and `635`), and it classifies again.
   This was the fix for the original bug.
3. The version from evaluating the project, at `library.rs:540` or at
   `library.rs:566`. The second one also guesses the old version from a tag
   in the lock on disk (`locked_tag`, `library.rs:469` and `569`), because
   by then `flake.nix` may already name the new tag.

A run makes up to three Nix calls, parses `flake.lock` twice, and reports
`from` as `Unknown` on one path (`library.rs:551`).

`kix upgrade` moves the library too, with its own copy of the logic in
`cli/kix-cli/src/commands/upgrade/pin.rs`. It finds the library input again
(`library_input`, `pin.rs:161`, with its own name list at `pin.rs:55`). It
reads the tag from `flake.lock` on disk (`locked_tag`, `tag_on_disk`,
`pin.rs:286-295`). It rewrites the tag in `flake.nix` by scanning for
quoted strings that contain `kix` (`retag_flake`, `pin.rs:133`). Then it
calls `library::lock` or `library::update_to` (`pin.rs:355-362`).

So the two commands disagree. With a tag in `flake.nix`, `kix lib update`
refuses and prints steps (`library.rs:336-356`), and `kix upgrade` edits
the file. A mirror or a fork is refused (`library.rs:318`), even when it
carries the same tags. With a branch in `flake.nix`, `kix lib update` locks
the tag anyway, so `flake.lock` contradicts `flake.nix`.

### Proposed design

**One function, `project::pin_library(dir, version, dry_run)`, in
`kix-core`. `kix upgrade` and the repair command both call it. It reads one
source: the lock that `flake.nix` gives now.**

Steps:

1. **Read.** Run `nix flake metadata --json --no-write-lock-file` once. Its
   `locks` field is `flake.lock` as Nix would write it from the current
   `flake.nix`. Kix never parses `flake.lock` on disk to decide anything.
2. **Find the input by name.** The library is the root input named `kix`
   or `kixpkgs`, or the one `kix.toml` names (`library-input = "..."`). No
   URL matching. A mirror or a fork is then the library like any other.
   When both names exist and `kix.toml` is silent, Kix stops and asks for
   the setting.
3. **Classify** by what `flake.nix` says the input follows (the `original`
   field of that one node), and act:

   | `flake.nix` says | Kix does | Kix prints |
   |---|---|---|
   | No ref, such as `github:kix-run/kix` | Locks the tag with `nix flake lock --override-input`. `flake.nix` is untouched. | `Kix library: v0.9.1 -> 0.10.0. Commit flake.lock.` |
   | A version tag, such as `.../v0.9.1` | Changes that tag in `flake.nix`, then runs `nix flake lock`. If more than one URL names the tag, it changes nothing and lists the lines. | `Kix library: v0.9.1 -> 0.10.0. Kix changed the tag in flake.nix. Commit flake.nix and flake.lock.` |
   | A branch or a commit | Nothing. The person chose it. | `The input kix follows the branch main, so Kix leaves it alone. It holds the Kix library 0.11.0-dev.` Then the compatibility result. |
   | A local path | Nothing. | `The input kix is the local folder ../kix, so Kix leaves it alone. It holds the Kix library 0.10.0.` Then the compatibility result. |
   | A mirror or a fork | The same as the rows above, by what it follows. | The same lines. When the tag is missing: `git.example.com/kix has no tag v0.10.0. Push the tag to the mirror, then run this again.` |

4. **Check, with the one evaluation.** Evaluate `kixLibrary.version` and
   pass it to `policy::library_compatible`
   (`cli/kix-core/src/version/policy.rs:128`). This is the only evaluation.
   It confirms what the project builds with after the move. It catches a
   mirror whose tag holds the wrong code and a branch that has drifted. On
   a mismatch Kix prints the existing policy message and exits non-zero.
5. **Dry run.** Run the same evaluation with `--override-input <name>
   <tag url>` and `--no-write-lock-file`. It proves the tag exists and
   holds the right version, and it writes nothing. This works for the tag
   row too, so a dry run never edits `flake.nix`.

The "before" side of the message is the tag or the short commit from the
lock read in step 1. That is a fact about the lock, printed as a tag, so
nothing is guessed. Nested inputs are no longer walked. If the check in
step 4 still finds the wrong version, the message says another input
supplies the library and names the `follows` line to add.

What goes from `library.rs`: `library_inputs`, `classify`, `kix_run_repo`,
`rev_at`, `locked_tag`, `current_lock`, `Action`, and the former-repository
rule (about 250 lines plus tests). From `pin.rs`: `library_input`,
`locked_tag`, `tag_on_disk`, `flake_edit`, and `LIBRARY_INPUT_NAMES` (about
120 lines). `retag_flake` moves to `kix-core` and takes the exact old URL
from step 1, so it stops searching for strings that contain `kix`.

Nix calls per run: read, write, check, with one evaluation.

### Should `kix lib update` exist?

My view: no, not as its own command.

- The name says "update the library", but the command makes the library
  match the Kix that is running. It is a group with one subcommand.
- It teaches that "the library" is a second thing to manage. Under the
  version rule (`policy.rs`) a project has one Kix version, written in
  three files: `kix.toml`, `flake.nix`, and `flake.lock`.
- Two commands that move the same files have already drifted apart.

The need behind it is real: the three files can disagree after someone
edits `kix.toml`, runs `nix flake update`, or wants to try a prerelease
(`upgrade/mod.rs:109` sends them to `kix lib update` for that). I would
serve it from `kix upgrade`:

- `kix upgrade --to <the version the project is on>` makes the three files
  agree and stops. It skips the release index and the before-and-after
  builds, because nothing is being upgraded.
- `kix upgrade --to <exact prerelease>` is allowed when the prerelease is
  named in full.
- About a dozen messages say "Run `kix lib update`" today (`policy.rs:166`,
  `eval/helm.rs:49,68`, `eval/error.rs:39`, `project.rs:447`,
  `legacy_domain/mod.rs:295`, `kix-bundle/src/lib.rs:315`). They change to
  the exact command with the version filled in, such as "Run `kix upgrade
  --to 0.10.0`". The message already knows the version.

If the command tree wants a separate verb for "repair", it should call the
same function. `kix pin` is taken by image pins. The verb matters less than
having one function.

### Alternatives rejected

- **Keep `flake.lock` on disk as the first source and patch the gaps.**
  That is today's design. Each gap needed another source.
- **Find the library by a hash the library publishes about itself.** The
  libraries this command must move are old ones that publish no hash.
- **Evaluate before the move as well, to print the old version number.**
  It adds an evaluation to show `0.9.1` where the tag `v0.9.1` says it.
- **Advance a branch to its newest commit.** That is `nix flake update`,
  and it cannot promise a library that matches this Kix.
- **Ship the library inside the release archive and pin nothing in the
  flake.** A mismatch could never happen and this part would vanish. But a
  project could no longer be built with plain Nix, and `flake.lock` would
  stop recording what the project builds from. It is too large for 0.10 at
  rc.3 and worth a design discussion before 1.0.

### Migration and breaking impact

- Removing `kix lib update` removes a command, so it needs an `error`
  record with a `cli` field and a line in `cli_surface.snap`. For one minor
  release, `kix lib update` stays as a hidden command that prints the id
  and the new command, as the versioning rules ask.
- A project with a nested library input used to be moved by path. It now
  gets a message. A project that follows a branch used to be locked to the
  tag. It is now left alone. Both go in the same record.
- `library-input` in `kix.toml` is a new optional setting. Update
  `kix-toml.mdx` and `cli/README.md`.

### Effort

Medium. It removes more code than it adds. The cost is rewriting the
`library.rs` tests (about 350 lines) and the pinning tests of `kix upgrade`
around the five rows of the table.

---

## Questions for the owner

1. **Raw Nix output.** People who build with plain Nix would see one extra
   machine-readable line at the end of each Kix error. Is that acceptable,
   or must output outside `kix` stay free of it?
2. **How much of the error migration goes into 0.10.0?** The minimum is
   about 60 places. The full job is about 500. The remainder is safe to do
   in patch releases. Do you want all packages converted before 0.10.0 so
   that the "no bare throw" test can be switched on at release?
3. **Package authors.** Some errors are aimed at the person who wrote a
   package, such as a hook that returns the wrong shape. Should those look
   different from errors aimed at the person who wrote the cluster
   definition? The design has room for a field and does not use one yet.
4. **One name for the library input.** The docs use `kixpkgs` in three
   places and `kix` in two. Should 0.10 settle on `kix` and accept
   `kixpkgs` as the old name?
5. **Tag or no tag in `flake.nix`.** Should the docs tell people to write
   the version tag in `flake.nix` (visible in review, survives a general
   input update, and Kix edits the file on upgrade), or to write the bare
   URL (Kix only ever touches `flake.lock`)? Both keep working. This
   decides what new projects get.
6. **Nested library inputs.** Does either current user get the library
   through another flake's input, such as a shared platform flake? If so,
   the plain message for that case is too little and it needs its own row.
7. **Following a branch.** Is "leave it alone and report" right for you
   when you develop against `main`, or do you rely on `kix lib update`
   locking the tag while `flake.nix` names a branch?
8. **The command.** Do you agree that `kix lib update` goes and `kix
   upgrade --to <current version>` does the repair? The agent redesigning
   the command tree may prefer a separate verb. The single shared function
   is the part I would hold on to.
9. **The former repository.** `kix lib update` has a special message for
   projects still on `kix-run/kixpkgs`. Have both users moved? If so, it
   can go with no replacement.
