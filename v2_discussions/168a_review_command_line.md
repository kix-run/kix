**Status:** Review input to doc 168 (2026-11-13). Doc 168 records the decisions; where they differ, 168 wins.

# Proposal: the Kix 0.10 command-line surface

Status: design only. Nothing in the repository was changed. Sources read: `cli/kix-cli/src/cli.rs`, `main.rs`, `tests/snapshots/cli_surface.snap`, the command files for `status`, `health`, `drift`, `doctor`, `plan`, `deploy`, `diff`, `gc`, `rollback`, `graph`, `inspect`, `secret`, and the reference pages under `docs/src/content/docs/reference/cli/`.

## 0. What the code says about the starting observations

| Observation | Verdict |
|---|---|
| Four commands answer "is my cluster OK?" | Three do. `doctor` checks the Kix installation and the project settings. It never contacts a cluster. Keep it separate. |
| `status`, `health`, `drift` overlap | Yes, and more than the names suggest. `status` lists readiness and always exits 0. `health` checks that each dependency is present. `drift` checks content and also reports missing objects. All three read the same set of live objects. |
| `status` needs a build | The flat view evaluates the project only to learn the cluster name. `status --operator` does not need the operator. It is the package-grouped view. The flag name is wrong. |
| Three commands answer "what will change?" | Two commands and one flag. `deploy --dry-run` calls `plan` directly. `diff` is a different thing: read-only, and it can compare two builds with no cluster. |
| Three upgrade verbs | Yes: `upgrade` (project), `self update` (installed Kix), `lib update` (make `flake.lock` match the installed Kix). Two words, "upgrade" and "update", for one idea. |
| `drift --cluster` | Yes. `list packages --cluster` is the second case. |
| `gc` has five `--include-*` flags | It has three (`--include-unstamped`, `--include-unattributed`, `--include-copies`) and three `--keep*` flags. |
| `deploy` display flags | Yes: `--tui`, `--group-by-ns`, `--fold-height`, `--log-format`. The middle two only matter with `--tui`. |

Other problems found:

1. `kix --help` says "Kubernetes manifest generator". The project says "Kix is a Kubernetes compiler."
2. Exit code 2 means "bad command line" (clap) and also "there are changes" (`diff`, `plan`). The exit-codes page admits a script cannot tell them apart.
3. `health`, `drift`, `check`, and `pin check` exit 1 for a finding. Exit 1 is also "could not reach the cluster". A cron job cannot tell drift from a network error.
4. An `-o` value that a command does not support is ignored without a message. `kix drift -o yaml` prints text. `kix plan -o json` is refused. `kix diff -o json` works. Three behaviors.
5. Two commands have their own format flag beside `-o`: `check --sarif` and `graph --format tree|dot|json`.
6. Four ways to name an output path: `--save FILE` (`plan`, `diff`), `--out DIR` (`export`, `compliance audit`), a positional (`bundle`, `snapshot save`).
7. Four groups hold one command each: `snapshot save`, `lib update`, `secret hash`, `migrate domain`.
8. Two queries are hidden in flags of commands that change things: `rollback --list` and `upgrade --ack`.
9. `gc` has no `--dry-run`. `upgrade` calls its dry run `--preview`. `deploy`, `rollback`, `migrate domain`, `lib update`, and `self prune` call it `--dry-run`.
10. Pruning is a three-way choice spread over two flags: `--prune` and `--prune-mode default|no`.
11. Internal words in flags and help: `--current-activation` (means "offline"), `--hard` (means "scan the whole cluster"), `export --for exit`, "Superseded activations" in `rollback --list`, "identity-hashes" in the one-line help of `health`.
12. The help of `kix check` tells the user to run `nix flake check`. `CLAUDE.prose.md` forbids pointing users at raw `nix` commands.
13. `apply` is a hidden alias of `deploy`, and a test forbids it in the docs. `pf` is the name and `port-forward` the alias, which is backwards.
14. `kix --help` lists 34 commands in one flat list with no grouping.
15. `cli_surface.snap` shows `kix self install` with no `<version>` argument, though `cli.rs` declares one. Worth a look at `cli_surface.rs`.

## 1. Proposed command tree

`<c>` is the cluster name. It is always the first positional argument. Flags every command has (`-v`, `-q`, `--no-color`, `-h`) are left out.

```text
Build and check (no cluster access)
  kix check <c>                 Evaluate the cluster, run checks and the scorecard
                                -o text|json|yaml|sarif
  kix build <c>                 Print the manifests            -o yaml|json
  kix graph <c>                 Show the dependency graph      -o tree|dot|json  --bundle FILE
  kix list clusters             Clusters in this project       -o text|json|yaml
  kix list packages [c]         Packages, with installed state when <c> is given
  kix list resources <c>        Resources by namespace and kind      (was: inspect)
  kix list images <c>           Container images  --sources          (was: images)
  kix diff <c> --from PATH      Compare this build with another build, a snapshot, or an export
                                --bundle FILE  --from-bundle FILE  --detail  --out FILE
                                -o text|json|yaml|markdown
  kix bundle <c>                Write the build as one .kixbundle file   --out FILE
  kix export <c>                Write the build as plain YAML   --out DIR  --with-kix-metadata  --force

Preview and deploy
  kix plan <c>                  Show what a deploy would change
                                --read-only  --offline  --prune  --reconcile  --force-conflicts
                                --accept-migrations  --bundle FILE  --deployed-bundle FILE
                                --out FILE   -o text|markdown
  kix deploy <c>                Apply the build to the cluster
                                (all plan flags)  --plan FILE  --dry-run  --yes  --on-error stop|continue
                                --timeout D  --operator  --record-annotation K=V
                                --log-format auto|pretty|line|json|tui  --group-by package|namespace
  kix rollback <c>              Go back to an earlier deploy
                                --dry-run  --yes  --prune  --force-conflicts  --operator
  kix history <c>               List the deploys Kix can roll back to   -o text|json|yaml
  kix gc <c>                    Delete resources and deploy records that are no longer needed
                                --dry-run  --yes  --full-scan  --include unstamped,unattributed,copies
                                --keep N  --keep-max N  --keep-for D  --operator

Operate
  kix status [c]                Is what Kix deployed present, unchanged, and ready?
                                --check readiness|presence|drift  --package NAME  -o text|json|yaml
  kix logs <c> <package>        Show a package's logs          -f  --tail  -c  --since  -p
  kix port-forward <c> <package> <ports>...   (alias: pf)      --address
  kix snapshot <c>              Save the cluster's Kix-managed objects for offline diffs  --out DIR
  kix migrate domain <c>        One-off move of Kix records to the kix.run API group  --dry-run  --yes

Project and installation
  kix upgrade                   Move this project to a newer Kix   --to V  --dry-run  --acknowledge ID...
  kix lib sync                  Make flake.lock match the installed Kix   --dry-run
  kix self install <V> | list | prune [--keep N --dry-run] | upgrade
  kix doctor                    Check the Kix installation and this project's settings
  kix pin set | rm | check | list        (unchanged)
  kix secret hash <file>        (pending, see section 6, question 7)
  kix compliance sbom | attest | audit   (unchanged, except audit keeps --out)
  kix completions <shell>
```

Rules the tree follows, so later commands stay consistent:

- **Cluster first, positional.** No `--cluster` flag anywhere.
- **`-o` picks the format of the result. An unsupported value is an error** that lists the values the command takes. No command has a second format flag.
- **`--out PATH` names a file or directory to write.** `--force` overwrites.
- **`--dry-run` exists on every command that changes a cluster or a project file.** `plan` is the full name for the dry run of `deploy`.
- **`--yes` skips a prompt.** Only commands that prompt have it.
- **One verb per idea.** "Upgrade" means move to a newer version. No command uses "update".
- **Words a new user knows.** "Deploy" (noun) for what the Activation record stores. "Offline" for "no cluster contact".
- **Exit codes** (section 3.4).

## 2. Every change from today

"Refused" means the old form stays as a hidden stub for one minor release and fails with an error that names the new form and prints the change record id `[Kxxxx]`. A stub is needed for removed commands in any case: without it, `kix health` would fall through to the plugin lookup and report a missing `kix-health` program.

| # | Old | New | Why | Refused |
|---|---|---|---|---|
| 1 | `kix health <c>` | `kix status <c> --check presence` | One command for "is my cluster OK?" | Yes |
| 2 | `kix drift [--cluster <c>]` | `kix status [c] --check drift` | Same. Also removes the `--cluster` flag. | Yes |
| 3 | `kix status <c>` (flat table, exit 0) | `kix status <c>` (by package, three checks, exit 2 on a problem). `-v` lists every resource. | Same. The exit code becomes useful. | No error. `silent` record: output, JSON shape, and exit code change. |
| 4 | `kix status --operator` | `kix status` (it is the default view) | The flag never needed the operator | Yes |
| 5 | `kix diff <c>` with no `--from` | `kix plan <c> --read-only` | One preview command. How much it can check is a flag. | Yes |
| 6 | `kix plan --current-activation` | `kix plan --offline` | Plain word | Yes |
| 7 | `--save FILE` on `plan`, `diff` | `--out FILE` | One name for "write here" | Yes |
| 8 | `kix bundle <c> [FILE]` | `kix bundle <c> [--out FILE]` | Same | Yes (extra positional) |
| 9 | `kix snapshot save <c> <dir>` | `kix snapshot <c> --out DIR` | A group with one command | Yes |
| 10 | `--prune-mode default\|no` | `--skip-orphan-check` (replaces `no`) | Two flags for one choice. `--prune` stays. | Yes |
| 11 | `kix deploy --tui` | `--log-format tui` | One flag picks how progress is shown | Yes |
| 12 | `kix deploy --group-by-ns` | `--group-by namespace` | Value flag, reusable by `status` | Yes |
| 13 | `kix deploy --fold-height N` | `KIX_TUI_HEIGHT=N` | A personal display setting | Yes |
| 14 | `kix apply` (hidden alias) | `kix deploy` | One name | Yes |
| 15 | `kix pf` | `kix port-forward`, `pf` stays as a listed alias | Full word first. Nothing breaks. | No |
| 16 | `kix rollback --list` | `kix history <c>` | A query should not be a flag on a command that changes the cluster | Yes |
| 17 | `kix gc --hard` | `kix gc --full-scan` | Says what it does | Yes |
| 18 | `kix gc --include-unstamped`, `--include-unattributed`, `--include-copies` | `--include unstamped,unattributed,copies` | One flag with a list | Yes |
| 19 | (none) | `kix gc --dry-run` | `gc` deletes things and has no preview in CI | Added |
| 20 | `kix inspect <c>` | `kix list resources <c>` | Fewer top-level commands. `list` already promises this. | Yes |
| 21 | `kix images <c>` | `kix list images <c>` | Same | Yes |
| 22 | `kix list packages --cluster <c>` | `kix list packages [c]` | Cluster is positional | Yes |
| 23 | `kix check --sarif` | `kix check -o sarif` | One format flag | Yes |
| 24 | `kix graph --format X` | `kix graph -o X` | Same | Yes |
| 25 | `-o` value a command does not support | Error that lists supported values | Scripts get what they asked for, or a failure | Is itself the error |
| 26 | `kix export --for exit\|audit` | default, and `--with-kix-metadata` | "exit" is an odd word for a mode | Yes |
| 27 | `kix self update` | `kix self upgrade` | One verb | Yes |
| 28 | `kix lib update` | `kix lib sync` | It does not choose a newer version. It makes the lock file match. | Yes |
| 29 | `kix upgrade --preview` | `kix upgrade --dry-run` | One name for "change nothing" | Yes |
| 30 | `kix upgrade --ack ID` | `kix upgrade --acknowledge ID` | Full word | Yes |
| 31 | Bad command line exits 2 | Exits 1 | Frees 2 to mean one thing | `silent` record |
| 32 | `about = "Kubernetes manifest generator"` | "Kix is a Kubernetes compiler." plus grouped command list | Positioning, and 30 commands need headings | No |
| 33 | `kix check` help names `nix flake check` | Remove the sentence, or name a `kix` command | Prose rule | No |

Unchanged: `build`, `deploy` (other flags), `logs`, `doctor`, `pin`, `compliance`, `completions`, `migrate domain`, `self install|list|prune`, global `--context`, `--flake`, `--no-cache`, `--override-input`.

## 3. The merges in detail

### 3.1 `kix status [c]`: one command for "is my cluster OK?"

It reads the live objects once and runs three checks on them. It needs a kubeconfig and nothing else: no build and no project. This keeps what `kix drift` can do today.

| Check | Question | Today |
|---|---|---|
| `presence` | Is every object of the current deploy, and everything it depends on, on the cluster? | `health`, and the "missing" part of `drift` |
| `drift` | Does each object still hold the content Kix applied? | `drift` |
| `readiness` | Is each object ready, by the rules `deploy` waits on? | `status` |

Default output:

```text
Cluster shop on Kubernetes v1.33 (context prod)
Last deploy: shop-7f3a  Active  2 days ago

  ingress-nginx     14 resources   ok
  postgres           9 resources   1 changed
  vaultwarden        6 resources   1 not ready, 1 missing

postgres
  ConfigMap db/pg-config            changed since deploy (field data.max_connections)
vaultwarden
  Deployment vault/vaultwarden      not ready (0/1 replicas)
  Secret vault/vaultwarden-db       missing, needed by Deployment vault/vaultwarden

29 resources: 26 ok, 1 changed, 1 not ready, 1 missing. 2 not checked.
```

- One line per package. Packages with a problem are expanded below.
- `-v` lists every resource (replaces the flat table). `-q` prints only problems.
- `--check X` (repeatable) runs only the named checks. `--package NAME` narrows to one package.
- With no `<c>`, it covers every Kix cluster in the kubeconfig context and names the cluster on each line. This works outside a project.
- `-o json|yaml` prints one object: `schema_version`, `cluster`, `kubernetes`, `deploy`, `packages[]`, each with `resources[]` that carry `ready`, `present`, `drift`. Today `status -o json` is a bare array and `health` has no JSON at all.
- Objects that cannot be checked (no applied-hash stamp yet, or no field ownership entry) are counted as "not checked" and do not fail the command. That is today's `drift` rule.
- Objects of a kind the account cannot read are also "not checked", with a note that names the kinds. Today `health` and `drift` report them as missing, and only `status` prints the note.
- The shared core in `proposal-deploy-secrets.md` section 3 (one `observe(...)` call, one fetch, three facts per object) is the implementation of this command. It also gives the JSON shape: one entry per object with all three facts.
- Exit codes: `0` every selected check passed. `2` at least one object is missing, changed, or not ready. `1` Kix could not answer (no cluster, no deploy record, no permission).

`kix plan` already says which drift a deploy would revert, so `status` only reports drift and names `kix deploy <c> --reconcile` as the fix.

### 3.2 `plan`, `diff`, and `deploy --dry-run`

- `kix plan <c>` is the preview in the default flow. It asks the API server to dry-run every write.
- `kix plan <c> --read-only` is today's `kix diff <c>`. It needs only `get` and `list`. It prints the list of things it cannot check (webhooks, ownership conflicts, refusals), as `diff` does today.
- `kix plan <c> --offline` is today's `--current-activation`. It does not contact the cluster.
- `kix diff <c> --from PATH` compares two builds and never contacts a cluster. A baseline is required. `kix diff <c>` alone is refused and names `kix plan <c> --read-only`.
- `kix deploy <c> --dry-run` stays as the same thing as `kix plan <c>`. It follows the `--dry-run` rule, and people type it from habit. `kix deploy --plan FILE --dry-run` keeps its job of checking a saved plan.
- Exit codes for `plan` and `diff` stay `0` no change, `2` changes, `3` the deploy would stop. `deploy --plan` keeps `4` for a stale plan.
- `-o`: `plan` takes `text|markdown`. `plan --read-only` and `diff` also take `json|yaml`, as `diff` does today. Section 6, question 3 asks whether `plan` should print JSON too.

### 3.3 Upgrade verbs

| Command | Moves | Notes |
|---|---|---|
| `kix upgrade` | The project (kix.toml and flake.lock) to a newer Kix | Unchanged apart from two flag names |
| `kix self upgrade` | The installed Kix to the newest release | Was `self update` |
| `kix lib sync` | flake.lock to the version of the installed Kix | Was `lib update`. Every error that names `kix lib update` changes with it. |

### 3.4 Exit codes, one table for the whole CLI

| Code | Meaning | Commands |
|---|---|---|
| 0 | Done, and nothing to report | all |
| 1 | Kix could not do it: an error, a bad command line, a failed check in `check` or `pin check`, a refused prompt on a non-interactive terminal | all |
| 2 | Done, and there is something to look at: changes (`plan`, `diff`), a problem (`status`) | `plan`, `diff`, `status` |
| 3 | A person must act before a deploy can go ahead | `plan` (would stop), `upgrade` (review) |
| 4 | The saved plan no longer matches | `deploy --plan` |

`kix upgrade` keeps `2` for "a build failed". It is the one exception and its page says so. `check` stays at 1 for a failed check, as linters do: a failed evaluation is the finding.

## 4. Alternatives rejected

- **Keep `health` and `drift` as aliases of `status --check`.** The repository rule is one name and an error for the old one. Aliases keep three pages of docs alive.
- **Keep three commands and only fix `drift --cluster`.** Cheapest. A new user still has to learn which of three commands to run, and none of them alone answers the question.
- **Fold `doctor` into `status`.** They check different things (the installation, the cluster). `doctor` must work when everything else is broken.
- **Remove `deploy --dry-run`.** It costs nothing, the habit is universal (kubectl, helm), and one rule ("every changing command has `--dry-run`") is easier to remember than an exception.
- **Remove `diff` completely.** Comparing two builds with no cluster is a real job (CI on a fork, upgrade review). It needs a name that is not "plan".
- **Keep `kix diff <c>` against the live cluster and only document the difference.** This is the fallback if question 2 is answered "no". It leaves two preview commands with different permissions, formats, and exit rules.
- **`kubectl`-style `kix get <thing>`.** Kix lists a few fixed things from a build. `list <noun>` is enough and already exists.
- **A `kix cluster ...` and `kix project ...` noun-first tree** (as in `gh`, `flux`). The four flow verbs (`check`, `plan`, `deploy`, `status`) would each gain a word. Grouping in `--help` gives the same overview at no cost to typing.
- **Move usage errors to exit 64 (sysexits).** Correct but unusual. `kubectl`, `gh`, and `terraform` use 1.
- **Renumber `plan` to 3/4/5 so that 2 stays the usage error.** Breaks both users' CI and departs from `terraform plan -detailed-exitcode`, which people know.
- **Per-command `-o` flags in place of the global one.** Cleaner in clap, but a larger refactor. A table of allowed values per command, checked in `main.rs`, gives the same behavior.
- **Fold `lib update` into `kix upgrade --lock-only`.** `upgrade` picks a target release and builds twice. The repair command must stay quick and work when the project does not build.
- **Rename `gc` to `clean` or `prune`.** `gc` is known from git and nix, and "prune" already names a deploy flag.
- **Rename `--flake` to `--project`.** See question 6. Not proposed for 0.10.

## 5. Effort and priority

Small: under a day. Medium: one to three days. Large: about a week. Each includes docs, the surface snapshot, and a change record.

| Change (table 2 rows) | Effort | 0.10? |
|---|---|---|
| `status` merge (1 to 4). A first version can run the three existing checks over one fetch and print the new layout. | Large | Must. Removing two commands is cheapest before more users arrive. |
| Refusal stubs helper: one function for removed commands and flags, with the record id | Small | Must. Everything else uses it. |
| Exit codes (31) and the `status` code | Small | Must |
| `-o` strictness, `-o sarif`, `-o dot` (23 to 25) | Medium | Must. Silent fallback is a correctness problem for scripts. |
| Positional cluster (22, and 2 through the merge) | Small | Must |
| `--out` everywhere (7 to 9) | Small | Must |
| Deploy display flags (11 to 13) | Small | Must |
| Verb cleanup (27 to 30) | Small | Must, if question 4 is "yes" |
| `--offline`, `--full-scan`, `--include`, `history` (6, 16 to 18) | Small each | Must |
| `about` line, grouped help, `check` help text (32, 33) | Small | Must |
| `gc --dry-run` (19) | Medium | Should. Can wait: it adds, so it never breaks. |
| `plan --read-only` and `diff` needs a baseline (5) | Medium | Should, if question 2 is "yes". The two commands share the plan document already. |
| `list resources`, `list images` (20, 21) | Small | Can wait for 0.11 |
| `port-forward` as the main name (15) | Small | Can wait. Not breaking. |
| `--skip-orphan-check` (10), `export --with-kix-metadata` (26) | Small | Can wait for 0.11 |

Dependencies: another agent is working on `health` for rc.3 (`changes/health-*.md`). Its fixes move into `status --check presence`. The fate of `kix secret hash` depends on the secrets review (question 7). The message text of every refusal needs the Argon copy pass.

## 6. Questions only the owner can decide

1. **One health command or three?** Today a user runs three commands to learn whether a cluster is as it should be: one for "are things running", one for "is anything missing", one for "has anyone changed something by hand". The proposal joins them into one command with one answer. The cost is about a week of work before 0.10.0. Do it now, or ship 0.10 with three and merge later with another breaking change?
2. **One preview command or two?** Today `kix plan` asks the cluster to rehearse the deploy, which needs write permission. `kix diff` only reads, so it works with read-only credentials, such as a CI job on a pull request. The proposal makes the second one a flag of the first (`kix plan --read-only`) and keeps `kix diff` only for comparing two builds. People know the word "diff" from other tools. Is one preview command worth losing that familiar name for the live comparison?
3. **Should the preview print JSON?** `kix plan -o json` is refused today, and the plan can only be saved to a file. `kix diff -o json` prints it. If the two are joined, either both print JSON or neither does. Was the refusal a deliberate choice (for example, because of size or secrets), or can `plan` print JSON?
4. **Is "upgrade" the one word?** The proposal uses "upgrade" for every move to a newer version and renames the lock-file repair from `kix lib update` to `kix lib sync`. Many error messages name `kix lib update` today, and both current users know it. Rename now, or keep `lib update` and accept two words?
5. **What should a failed health check return to a script?** The proposal uses exit code 2 for "Kix ran fine and found a problem", and 1 for "Kix could not run". The alternative keeps 1 for both, as today. The first lets a monitoring job tell a broken cluster from a broken network. It also means a mistyped flag returns 1 where it returned 2. Agree?
6. **Should the command line say "flake"?** `--flake` and `--override-input` are Nix words, and the prose rules assume most readers do not know Nix. Kix already calls the directory "the project". Should a later release offer `--project` for the directory, and keep `--flake` for people who pass a remote reference? Not proposed for 0.10.
7. **Does `kix secret hash` stay?** It was added so that a user can paste a hash of a secrets file into the cluster definition. Another review is deciding whether that hash should exist. If the hash goes, the `secret` group goes with it. If it stays, should the command write the hash into the file for the user, so nothing is pasted by hand?
8. **Short names.** The proposal keeps `pf` as a listed short form of `port-forward` and removes the hidden `apply` alias of `deploy`. Is a small set of listed short names acceptable, or should every command have exactly one name?
9. **Where do retention settings live?** `kix gc` takes three flags (`--keep`, `--keep-max`, `--keep-for`) that decide how many past deploys stay available for rollback. A team must pass the same values on every run. Should these move to the cluster definition or `kix.toml`, with the flags as overrides?
10. **How long does `kix migrate domain` stay?** It moves records from the API group that Kix used before it was renamed. Both current clusters have run it. Can 0.11 remove it, given the six-month promise for reading old cluster state?
