**Status:** Review input to doc 168 (2026-11-13). Doc 168 records the decisions; where they differ, 168 wins.

# Code structure audit of `cli/` before outside contributors arrive

Scope: the Rust workspace under `cli/` at 0.10.0-rc.3. I read the code and measured it. I built nothing and ran no tests. Line numbers are from `main` at `8caf0177`.

## Size of the workspace

| Crate | `src` lines | Of which tests (approx.) | Role |
|---|---|---|---|
| `kix-core` | 16,870 | 5,500 | evaluation, project config, manifests; no Kubernetes client |
| `kix` (package `kix-lib`) | 46,747 | 23,100 | cluster operations, planning, releases, pins |
| `kix-cli` | 26,156 | 6,100 | the `kix` binary |
| `kix-bundle` | 2,410 | 1,100 | bundles |
| `kix-operator` | 1,921 | small | the operator binary |

There are 3,581 functions. 59 are longer than 100 lines and 26 are longer than 150. The ten longest are listed under problem 1 and problem 4, because those two problems produced most of them.

## The ten problems, most important first

### 1. The deploy pipeline is assembled in the binary, so each caller assembles it again

**Evidence.**
- `kix-cli/src/commands/deploy/mod.rs:46` `run` is 251 lines. It decides whether a migration stops the deploy, whether a dry run is needed, whether a saved plan is stale, whether "nothing to apply" still has to rerun failed Jobs, and when to supersede old records. Printing, the `[y/N]` prompt, and six `process::exit` calls sit between those decisions.
- `run_deploy_async` (`deploy/mod.rs:559`) takes nine positional arguments. Eight functions in the workspace carry `#[allow(clippy::too_many_arguments)]`.
- `kix-cli/src/commands/rollback.rs:210` `run_async` (256 lines) and `:467` `run_operator_async` (172 lines) share their first 60 lines. A diff of lines 225-300 against 476-551 shows 31 changed lines, most of them one error message.
- `rollback.rs:710` `plan_rollback` runs the binding check, the Kubernetes version note, the baseline, and the planner by hand. `commands/plan.rs:138` `prepare` does it through `Planner::run`. `gc/mod.rs:216` and `:387` call `binding::check` twice more. `kix-operator/src/controller.rs:225` `reconcile_activation` (201 lines) sequences the same checks a fourth way.
- The required-stop check lives only in the binary (`kix-cli/src/commands/deploy/stops.rs:25`, called from `deploy/mod.rs:86`). The operator and any program that depends on `kix` deploy without it.

**Why it matters.** A contributor who adds a pre-deploy check must find four call sites, and nothing tells them the fourth exists. The rule "a deploy never skips a required stop" is a promise about cluster state, and today only one of the callers keeps it. Kix Enterprise depends on `kix`, so it inherits none of the binary's decisions.

**Fix.** Add one library entry point in `kix::cluster` (or a new `kix::deploy` module) that owns the sequence: load the target, run the preflight checks (binding, Kubernetes version, required stops, record gate), plan, dry run, and execute. It returns typed outcomes such as `Outcome::NothingToApply`, `Outcome::Refused(Refusal)`, `Outcome::NeedsConfirmation(Plan)`, and `Outcome::Finished(RunEnd)`. It takes one `DeployRequest` struct in place of nine arguments. The binary keeps what only a terminal program does: render the plan, ask the question, choose the exit code. Rollback becomes the same call with a different target, and the direct and operator paths share target selection. The operator calls the same preflight function.

**Effort.** Large. **Risk.** Medium to high: this is the path that writes to clusters. The scripted scheduler tests and the kind integration tests cover the engine well, so move the code in steps and keep each step behaviour-neutral.

### 2. Errors have no common design, and messages are written in three places

**Evidence.**
- The library crates define 36 error types. `README.md:1220` says "Libraries use `thiserror`, and binaries use `miette`", yet about 100 library functions return `Result<_, String>`: `kix/src/pins/mod.rs:172-629` (8), `kix/src/legacy_domain/` (33), `kix-core/src/build_source.rs` (11), `kix/src/plan/baseline.rs` (7), `kix/src/plan/planner.rs:391`.
- `kix-cli` contains 226 `miette!(...)` calls that write new user-facing messages, 86 `into_diagnostic()` calls, and about 100 `map_err(|e| miette!("{e}"))` calls. The last form turns a typed error into a string and drops its source chain, so no caller can match on it afterwards.
- `kix-operator/src/controller.rs:86` `OperatorError` has four `(String)` variants, filled by 11 `map_err(|e| OperatorError::X(e.to_string()))` calls.
- Messages follow at least three layouts. Some are one sentence plus `Next:` (90 uses). Some are an indented block with `Why:` and `Next (choose one):` (42 and 18 uses). Some are a bare sentence. The sentence "Nothing was applied/changed/deleted" is typed out 81 times across three crates. `kix-cli/src/commands/mod.rs:126` and `kix-core/src/eval/error.rs:8` hold two wordings of the same "cluster not found" error.
- `miette` is used as a string carrier. No error implements `Diagnostic`, so codes, help text, and labels are unused.

**Why it matters.** A contributor cannot tell where a new message belongs, which layout to use, or whether a caller depends on the error's type. The Argon copy pass and `CLAUDE.prose.md` define one voice, and the code gives no single place to enforce it.

**Fix.** Decide the rule and write it at the top of `cli/README.md`:
1. Every public library function returns a typed error. Remove `Result<_, String>` from public signatures.
2. Give user-facing errors one shape, for example a small `Report { what, unchanged, why, next: Vec<String>, id: Option<ChangeId> }` in `kix-core`, with one renderer. The three layouts become one function. "Nothing was applied" becomes an enum value.
3. In the binary, implement `From<LibError> for CliError` once per error type. Delete the `map_err(|e| miette!("{e}"))` calls. `CliError` carries the exit code (see problem 3).
4. Either use `miette::Diagnostic` properly (help and code fields) or drop `miette` for `anyhow`-style reporting plus the renderer above. I recommend keeping `miette` and implementing `Diagnostic` on `Report`.

**Effort.** Large if done everywhere. Medium if you do steps 1 and 3 now and migrate messages to the single shape command by command. **Risk.** Low for behaviour. High for test churn until problem 7 is fixed, because tests pin the wording.

### 3. Exit codes are a public API, and 23 scattered `process::exit` calls implement it

**Evidence.**
- `std::process::exit` appears at 23 sites in `kix-cli/src/commands/` plus `output.rs:275`. Examples: `deploy/mod.rs:104, 141, 162, 293, 813, 910`, `plan.rs:98, 101`, `check.rs:350, 362`, `gc/render.rs:268`.
- Exit code constants live in three files: `plan.rs:45-47` (2, 3), `deploy/saved_plan.rs:15` (4), `upgrade/mod.rs:33-37` (1, 2, 3). Code 2 means "plan has changes" in one and "build failed" in another. `diff.rs:176` uses a literal `2`.
- Helper functions exit from inside: `stops::check` (`deploy/stops.rs:51`), `output::refuse_unconfirmed` (`output.rs:275`), and `gc/render.rs:268` return `!` or never return.

**Why it matters.** `CLAUDE.md` says changing an exit code is a breaking change. Nothing lists the codes, and no test can call these functions without ending the test process. Exiting in the middle of a function also skips destructors, so temporary files and terminal state depend on luck.

**Fix.** One `enum Exit` in `kix-cli` with every code and its meaning. Commands return `Result<Exit, CliError>`. `main` is the only caller of `process::exit`. Add a `clippy.toml` `disallowed-methods` entry for `std::process::exit` outside `main.rs`. Print the table in the docs from the enum.

**Effort.** Small to medium. **Risk.** Low. The integration tests assert exit codes already.

### 4. Large parts of `kix-cli` are domain logic that other programs cannot reuse or test without the binary

**Evidence.**
- `commands/upgrade/` is 3,518 lines. `upgrade/mod.rs:39` `run` is 480 lines, the longest function in the workspace, with 92 `println!` calls in the file. It holds the upgrade state machine (resume, step-through, acknowledgements).
- `commands/compliance/` is 1,773 lines of SBOM, SLSA, SARIF, and OSCAL construction, with 52 hand-built `json!` documents.
- `commands/health.rs:274` `walk_graph` and `:394` `group_by_package` compute health from the dependency graph inside the command.
- `commands/status.rs:674` `compute_status` reads `/status/readyReplicas` and friends from raw JSON to decide readiness per kind. The library already decides readiness per kind in `kix/src/cluster/readiness/declared.rs:415` `check_readiness`. Two tables now answer "is this Deployment ready".
- `commands/gc/plan.rs` (423 lines) plans what garbage collection deletes. `commands/pin/locate.rs` (336 lines) finds pin sites.
- `kix-cli` has no library target (`kix-cli/Cargo.toml:8`), so `kix-cli/tests/` can reach this logic only by running the binary. All ten test files there spawn it with `cargo_bin`.

**Why it matters.** The README describes `kix-cli` as "clap CLI, command dispatch, plan display". A newcomer expects thin commands and finds a third of the workspace's non-test logic there. Kix Enterprise and the operator cannot call any of it.

**Fix.** Move decision logic down and keep rendering up. Concretely: `upgrade` planning and state into `kix::upgrade` (it needs no Kubernetes client, so `kix-core` may be the better home, see problem 9); compliance documents into a `kix-compliance` crate or `kix::compliance` behind typed structs; health and status computation into `kix::cluster::health` sharing one readiness table; gc planning into `kix::cluster`. Each command file should then read as: parse arguments, call one library function, render the result.

**Effort.** Large in total, but each move is independent and medium on its own. **Risk.** Low to medium. Start with `status`/`health` (removes a real duplicate) and `upgrade` (largest win).

### 5. Adding a command means editing five places that the compiler does not connect

**Evidence.**
- `kix-cli/src/cli.rs` (1,598 lines) holds every argument struct. A new command also needs an arm in `Command::cluster_name` (`cli.rs:418-459`) and an entry in `SCOPED_GLOBALS` (`cli.rs:86`).
- `main.rs:144-272` is a ladder of nine `if let Command::X = ... { return ... }` blocks, each with a comment explaining why that command must run before some setup step. The final `match` ends with nine `unreachable!()` arms (`main.rs:262-270`).
- `main.rs:88` `output_mode` holds a second per-command table (default format, whether progress goes to stderr).
- `CommandContext::new` (`commands/mod.rs:63`) always creates an evaluator and a Tokio runtime. Commands that need neither, or only one, bypass the context and take `&GlobalArgs`. So there are two calling conventions, and `block_on` appears 34 times across 13 command files.
- 13 files call `make_client` directly. Each then opens records, resolves the cluster name, and maps errors its own way.

**Why it matters.** The order of the ladder encodes real requirements (drift must work without a project, `pin` must work when evaluation fails). They are enforced by position in `main`, and a contributor who adds a command in the wrong place breaks one silently.

**Fix.** Give each command a declared set of needs, for example `enum Needs { Nothing, Project, Runtime, Evaluator, Cluster }`, returned by one method on `Command`. `main` builds a context lazily from the needs and dispatches through a single `match` with no `unreachable!`. Make `CommandContext` hold lazy fields (`evaluator()`, `client()`, `records(cluster)`) so every command goes through it. Make `main` `async` or give the context one `block_on` helper. Split `cli.rs` into one file per command group next to its `run`.

**Effort.** Medium. **Risk.** Low. `cli_surface.snap` proves the surface did not move.

### 6. Text is matched where structured data exists or could exist

**Evidence.**
- `kix-core/src/eval/nix.rs:633-647` `names_its_fix` decides how to present an evaluation error by matching the Kix library's own messages: `"error: cluster '"` plus `" problem(s):"`, a `Fix: ` line prefix, `"error: The option \`"`, and a hand-rolled scan for `[Knnnn]`. Both ends of this protocol are in this repository, so a rewording in `kix/lib` changes CLI behaviour with no compile error.
- `nix.rs:106` and `:397` match Nix's stderr (`"does not provide attribute"`, `"allow-import-from-derivation"`). `kix-core/src/system_nix.rs:30` matches `"Lix"`.
- `kix/src/cluster/preview.rs:218-287` and `kix/src/cluster/apply/ssa.rs:551-566` classify apiserver refusals by substrings of the message. Kubernetes `Status` objects carry `reason` and `details.causes[].reason` and `.field`, which answer several of these questions (for example `FieldValueInvalid` on `status.storedVersions`).
- Activation phases are `String` (`kix/src/cluster/activation/record.rs:16`) compared against `PHASE_*` constants. The constants are referenced about 100 times in 14 files. `Record` keeps `deployed_at` and `failed_at` as `Option<String>` beside a parsed `created_at`. `upgrade/mod.rs:341` compares `last.result == "ok"`.
- The code reads objects through `Value::pointer("/...")` about 195 times outside the test-only files, 74 of them in `cluster/readiness/`.

**Why it matters.** String protocols fail at run time, on a user's cluster. They are also the hardest code for a newcomer to change safely, because the other half of each protocol is somewhere else.

**Fix.** In priority order:
1. Make the Kix library emit its own errors in a structured form the CLI parses, such as one JSON line with `id`, `kind`, `fix`, and `message` inside the thrown text. Keep the substring fallback for libraries older than 0.10 and delete it in 0.11.
2. `enum Phase` with `#[serde(other)] Unknown(String)`, so an unknown phase from a newer Kix still reads. This respects the six-month state rule.
3. Read `Status.reason` and `details.causes` first in `preview.rs` and `ssa.rs`, and fall back to message text only for the webhook cases that have no structured form. Keep the existing comment that says the text is the apiserver's wording.
4. Deserialize the handful of workload status shapes into `k8s-openapi` types in `readiness/` in place of pointer chains.
Nix's own stderr has no structured alternative. Keep those matches, in one file, each with a test that feeds real captured stderr.

**Effort.** Medium (items 1 and 2), small (item 3), medium (item 4). **Risk.** Item 1 touches the library contract and needs a change record. Item 2 touches cluster state reading, so add fixtures first.

### 7. Many tests pin message wording, so a copy edit breaks dozens of them

**Evidence.**
- About 200 assertions check for a message substring of 25 characters or more: 122 in `kix-cli`, 42 in `kix`, 23 in `kix-core`. `kix-cli/tests/upgrade_test.rs` has 51 `contains(...)` assertions on output text, for example line 383, which pins two full lines including indentation.
- Library tests pin whole sentences of remedy text: `kix/src/cluster/binding.rs:747-923`, `kix/src/cluster/kubernetes_version.rs:537-633`, `kix-operator/src/controller.rs:889-892`.
- `CLAUDE.md` already warns that after the Argon copy pass "some [tests] check message text word for word".
- Only six `insta` snapshots exist, all in `kix-cli/tests/snapshots/`.

**Why it matters.** The project has a mandatory copy-edit pass on every user-facing string. Each pass breaks tests that were never about wording. A contributor cannot tell which substring is the contract (an identifier, a command to run) and which is incidental prose.

**Fix.** Two kinds of test, kept apart:
- Behaviour tests assert on structure: the error variant, the `Report` fields from problem 2 (`next` contains the command `kix deploy prod --prune --accept-migrations`), the exit code.
- Wording tests are `insta` snapshots of the full rendered message, one per message. A copy edit is then reviewed as a snapshot diff and accepted with one command.
Adopt this for new code now and convert the old assertions as each message moves to the single shape.

**Effort.** Medium, spread over time. **Risk.** Low.

### 8. `cli/README.md` cannot be read, and the first thing it teaches is a naming trap

**Evidence.**
- The file is 1,222 lines and about 79,000 tokens. 23 lines are longer than 1,500 characters. Line 1175 is one bullet of 13,011 characters, and line 1180 is 10,816.
- Lines 95-255 describe the release workflow, the self-hosted runner names, and what kix.run serves. A code contributor needs none of it to find their way.
- "Where things live" starts at line 895. Its `kix-cli` section covers `client.rs`, `plugin.rs`, `cli.rs`, `plan/`, and `output.rs`. Twenty-two command files and three command folders are named elsewhere, inside running prose about other subjects. `commands/status.rs` (925 lines) is not named by path at all.
- The directory `kix/` is the package `kix-lib` with library name `kix`. The directory `kix-cli/` builds the binary `kix`. `cargo test -p kix` fails; the README's own example uses `-p kix-lib` (line 86).
- Four unrelated things are called "migrate": `kix/src/cluster/migrate.rs` (stateful migration pairs), `kix/src/legacy_domain/migrate.rs` (API domain), `kix-cli/src/plan/migrations.rs` (rendering the pairs), and `kix-cli/src/commands/migrate.rs`. Two modules are called `plan` (`kix::plan` and `kix_cli::plan`), and two are called `deploy_log`.
- `README.md:1220` states an error rule the code does not follow (problem 2).

**Why it matters.** The README is the stated entry point. At this size it works as a search target for an agent and fails as an introduction for a person. Contract-level detail in it goes stale without anyone noticing.

**Fix.** Split it. Keep `cli/README.md` under about 150 lines: what each crate is for, the dependency rule for `kix-core`, how to build and test, the error and exit-code rules, how to add a command, and a table of modules with one line each. Move subsystem detail into module-level `//!` docs beside the code, where rustdoc checks the links. Move the release process to `docs/` or `RELEASING.md`. Rename the directory `kix/` to `kix-lib/` (or the package to `kix`), rename `cluster/migrate.rs` to `stateful_pairs.rs`, and rename `kix_cli::plan` to `render`.

**Effort.** Medium for the split, small for the renames. **Risk.** Low. Update the `CLAUDE.md` pointer that names the README as the LLM reference.

### 9. The `kix` crate boundary is "everything that is not `kix-core`"

**Evidence.**
- `kix/src/release/` (1,552 lines), `installs.rs`, `pins/` (1,000), and `registry/` (809) contain no reference to `kube` or `k8s_openapi`. They sit in `kix` because they need `reqwest`, `ring`, `tar`, and `flate2`, which `kix-core` must not link. `kix-operator` depends on `kix` and so compiles the release installer and the registry client.
- `kix/src/cluster/mod.rs` declares 28 sibling modules in one flat namespace: transport (`client`, `errors`, `discovery`), state (`activation`, `tenancy`, `binding`), the engine (`scheduler`, `apply`, `readiness`, `watchdog`, `cancel`, `stream`), and analysis (`drift`, `owned_view`, `fieldsv1`, `topology`, `preview`).
- `kix/src/manifest/mod.rs` and `kix/src/legacy_domain/mod.rs` start with `pub use kix_core::<module>::*` and add functions, so `kix::manifest` is a different module from `kix_core::manifest` with the same contents plus extras. The README needs a paragraph (lines 18-34) to explain it.
- `kix-core/src/runtime.rs:421` keeps the selected builder in a process-wide `OnceLock`. A program that embeds `kix-core` can build with only one builder per process, and tests cannot vary it.

**Why it matters.** Crate boundaries are the cheapest architecture documentation there is. Today they say "no C code" and "the rest". Contributors working on the deploy engine rebuild the release client, and the reverse.

**Fix.** Split by responsibility while 0.10 allows it: `kix-core` (unchanged, keeps the Lithus guarantee), `kix-cluster` (everything that takes a `kube::Client`, with `cluster/` grouped into `transport/`, `records/`, `engine/`, and `analysis/` submodules), `kix-plan`, and `kix-release` (release, installs, registry, pins). Keep `kix` as a thin facade crate that re-exports them, so Kix Enterprise's imports do not change. Replace the glob re-export trick with extension traits or plainly named modules (`kix_cluster::live_manifest`). Pass the builder in an explicit `EvalContext` and keep the global only in the binary.

**Effort.** Medium to large, mostly mechanical. **Risk.** Low for behaviour. `kix/tests/package_test.rs` already checks that crates build alone, so extend it to the new crates.

### 10. Machine-readable output is built by hand per command, and most of it has no schema

**Evidence.**
- Nine types implement `CommandResponse` (`output.rs:296`), whose JSON side is `fn as_json(&self) -> serde_json::Value`. The implementations build the value with `json!` (`status.rs:49`, `list.rs`, `check.rs`, `inspect.rs`).
- Other commands skip the trait and branch on `output::format()` themselves: `pin.rs` (8 sites), `plan.rs` (5), `diff.rs` (5), `rollback.rs` (4), `drift.rs`, `images.rs`.
- `kix-cli/schema/` holds three schemas (plan, plan file, deploy log). `status`, `check`, `list`, `drift`, `rollback --list`, `pin`, and `inspect` print JSON with no schema and no snapshot.
- A format a command cannot print is refused by hand in the command (`deploy/mod.rs:57-70`), so each command decides for itself what `-o yaml` means.

**Why it matters.** `CLAUDE.md` says removing or renaming a JSON field is a breaking change that needs a change record. For most commands no check can notice one. The Change kind workflow reads only `cli/kix-cli/schema/`.

**Fix.** Change the trait to `trait CommandResponse: Serialize + JsonSchema { fn format_text(&self) -> String; }`. Every command returns one typed response, and `output::result` handles JSON, YAML, and the "this command has no such format" refusal in one place. Generate a schema per response into `kix-cli/schema/` with the existing `schemas.rs` test. The response structs belong in the library once problem 4 moves the logic there.

**Effort.** Medium. **Risk.** Low, if each conversion is checked against the current output with a snapshot first. Field order may change, which is not a break for JSON readers.

## Why the large files and functions got large

Three causes account for nearly all of them.

1. **Messages inline.** Multi-paragraph messages are written inside control flow (`upgrade/mod.rs:39-520`, `rollback.rs:210-466`, `kix/src/cluster/binding.rs:222` `render`, 254 lines). Problem 2 removes this.
2. **Decide, print, and exit in one function.** `deploy::run`, `gc::run_soft` (221 lines), `plan::document` (259), `health::run`. Problems 1, 3, and 4 separate them.
3. **Tests in the same file.** Half of `kix` is test code. `plan/baseline.rs` is 1,668 lines with 692 of tests; `cluster/client.rs` is 1,309 with 675. This is normal Rust and I would leave it, except to move any test module over about 400 lines to a sibling `tests.rs`, as `scheduler/` and `readiness/` already do.

Two long functions are long for good reasons and need only internal splitting: `scheduler/node.rs:115` `execute_node` (304 lines, one state machine) and `kix-core/src/eval/store_graph.rs:713` `synthesize_placed` (241).

## Suggested order

1. Problems 3 and 5 first. They are small, low risk, and make every later change easier to review.
2. Problem 2 steps 1 and 3 (typed errors, one conversion point), together with the test rule from problem 7.
3. Problem 1, then problem 4, one command at a time.
4. Problems 9 and 8 together, since the crate split rewrites the README's map anyway.
5. Problems 6 and 10 can run in parallel with any of the above.

## Done well: keep these

1. **The `kix-core` boundary is real and tested.** Its dependency list has no async runtime, HTTP client, or C code, and `kix/tests/package_test.rs` checks each crate builds alone. Both library crates set `#![deny(clippy::print_stdout, clippy::print_stderr)]`, and the only `println!` in them is in a test fixture writer.
2. **The deploy engine reports through one event stream.** `DeployEvent` and `DeployObserver` (`kix/src/cluster/stream.rs`) feed the line renderer, the JSON deploy log, the TUI in `graph_stream.rs`, the operator's logs, and Kubernetes Events. The engine knows nothing about terminals. Problem 1 should extend this design to the steps before the engine starts.
3. **The test doubles are strong.** `cluster/fake_api.rs` is an in-memory apiserver behind a real `kube::Client`, `ops/scripted.rs` scripts the engine's side effects, and the scheduler tests run on a paused clock. Add to these the proptest suite in `kix-bundle/tests/plan_bound.rs` and the fuzz targets.
4. **Compatibility is checked by machines.** `cli_surface.snap` pins commands and flags, `kix-cli/schema/` pins three documents, and `cluster/state_fixtures.rs` reads cluster state written by older releases. Problem 10 asks for more of the same.
5. **Retired behaviour is fenced in.** `legacy_domain` reaches the rest of the code through four named hooks and documents its own removal (`kix-core/src/legacy_domain/mod.rs:9-39`). `version/policy.rs` is the single place that compares versions. New compatibility code should copy this pattern.
