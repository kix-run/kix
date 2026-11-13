# 168: The 0.10 clean-up

**Status:** Implementation Plan / Accepted
**Related:** `163_cli_install_versions_and_upgrades.md`, `167_secrets_only_through_dependencies.md`

Four reviews written on 2026-11-13 fed this plan: `168a_review_command_line.md`,
`168b_review_library_contract.md`, `168c_review_deploy_secrets_status.md`,
and `168d_review_code_structure.md`. References such as "168d problem 3" point
into them. It settles where they disagreed
and orders the work. Checked against the code: the required-stop check is only in the
CLI (`cli/kix-cli/src/commands/deploy/stops.rs`); the SOPS file is already
copied into the build (`kix/lib/scope/builders.nix:920-945`) and the hand-kept
`hash` is a digest of the decrypted values (`cli/kix/src/cluster/secrets.rs:661`).

## The rule that splits the work

0.10.0 must contain every change a user can see break: commands, flags, exit
codes, JSON fields, library functions, cluster state. After 0.10.0 those cost
another minor release and another round of refusal messages.

Internal changes (crate layout, error types, where code lives) break nothing
for users. The Rust crates are not a public API. They can land before or
after 0.10.0, in patch releases. Some of them come first anyway, because they
make the visible changes smaller.

## Where the proposals disagreed, and the call

1. **`kix lib update`.** The CLI proposal renames it `kix lib sync`. The
   library proposal removes it and has `kix upgrade --to <current version>`
   do the repair. Call: remove it. Both proposals agree on one shared
   function behind it. One command that moves the three files (`kix.toml`,
   `flake.nix`, `flake.lock`) is easier to explain than two. The objection
   (upgrade builds twice) goes away because the library proposal skips the
   builds when the target is the current version. Every message that says
   "Run `kix lib update`" names the exact `kix upgrade --to X` command.
2. **`kix secret hash`.** Goes with the hand-kept hash. The `secret` group
   disappears. Neither shipped in a stable release.
3. **`status` merge and the shared core.** No conflict. The `observe()` core
   is the implementation of the merged `kix status`.

## Stage 1: foundations (internal, no user change, about 2 days)

So that the visible changes land in one place each.

- One `Exit` enum. `main` is the only caller of `process::exit`. Clippy bans
  it elsewhere. (168d problem 3)
- Command dispatch from declared needs, no `unreachable!` ladder. Split
  `cli.rs` by command group. Refusal-stub helper for removed commands and
  flags. (168d problem 5, 168a section 2)
- Typed command responses: one `CommandResponse: Serialize + JsonSchema`,
  one place that handles `-o` and refuses unsupported formats. (168d problem 10)
- Move the required-stop check into the library and call it from the
  operator. This is a correctness fix. (168d problem 1, the part that cannot wait)
- New test rule: behaviour tests check structure, wording is checked by
  `insta` snapshots. Applies to new code from here on. (168d problem 7)

## Stage 2: the visible changes (must be in 0.10.0, about 1.5 weeks)

Can run as three parallel branches after stage 1.

**A. Command line** (168a, table 2)
- `kix status` replaces `health` and `drift`, built on `observe()`. Three
  checks, by package, exit 0 / 2 problem / 1 could not answer. Kinds the
  account cannot read are "not checked", not "missing".
- Exit codes: 2 only means "something to look at"; a bad command line is 1.
- `-o` strict everywhere; `check -o sarif`, `graph -o dot`.
- Cluster always positional. `--out` for every output path.
- `plan --read-only` replaces `diff <c>`; `diff` needs `--from`.
- Renames: `--offline`, `history`, `gc --full-scan`, `gc --include`,
  `self upgrade`, `upgrade --dry-run`, `--acknowledge`, deploy display flags,
  `port-forward` (keep `pf`), remove hidden `apply`.
- `kix --help`: "Kix is a Kubernetes compiler.", commands grouped.
- `gc --dry-run` (an addition, can slip to 0.10.x).

**B. Library contract** (168b part 1, 168c section 2)
- `kix.fail` / `scope.fail` with the `kix-error/1` JSON line. Convert the
  about 60 sites that carry an id or a `Fix:` line. Delete the text rules in
  `nix.rs`. The other 440 throws move in 0.10.x; nothing regresses meanwhile.
- `kixLibrary.projectRoot` so the CLI stops knowing library folder names.
- Remove the SOPS `hash`. The library computes a digest of the encrypted
  file (`kix.run/sops-digest`). Two `error` records, one `note` (pods that
  read a SOPS Secret restart once).

**C. Pinning and deploy safety** (168b part 2, 168c sections 1 and 3)
- `pin_library()` in `kix-core`, one Nix read, input found by name. Used by
  `kix upgrade`. `kix lib update` removed with a refusal.
- Webhook dry run: one classifier in the library used by plan, deploy, and
  rollback; "this deploy writes the Service" only when the plan applies it;
  no retries of a dry-run 500; settle the JSON reason name.
- `observe()` core (needed by A).

Then rc.4, the same test pass as rc.2 and rc.3 (monorepo, kind), then 0.10.0.

## Stage 3: internal quality (0.10.x, no release blocks on it)

In this order. Each step is behaviour-neutral and goes in its own PR.

1. Typed errors: no `Result<_, String>` in public library functions, one
   conversion into the CLI error, one message shape and renderer. (168d problem 2)
2. Deploy pipeline as one library entry point; rollback and the operator call
   it. (168d problem 1)
3. Domain logic out of `kix-cli`: upgrade, compliance, gc planning. (168d problem 4)
4. Crate split (`kix-cluster`, `kix-release`, ...), directory `kix/` renamed
   to match its package, README cut to about 150 lines with module docs
   beside the code. (168d problem 8, 9)
5. Kubernetes `Status.reason` before message text; `enum Phase`. (168d problem 6)
6. The remaining 440 bare throws to `scope.fail`, then turn on the test that
   forbids bare `throw` in packages.

## Decisions

Adam decided on 2026-11-13:

1. `health` and `drift` merge into `kix status` in 0.10.
2. `kix plan --read-only` replaces `kix diff <cluster>`. `kix diff` stays
   only for comparing two builds.
3. `kix lib update` is removed. `kix upgrade --to <version>` repairs a
   mismatch.
4. The SOPS `hash` is removed. Kix computes a digest of the encrypted file.

Taken as recommended unless Adam objects:

5. Exit code 2 means "found something". A bad command line exits 1.
6. Errors from the library end with one machine-readable line, which people
   who build with plain Nix also see.
7. A broken webhook that the deploy does not repair stops the deploy before
   it starts.
8. The deploy record gains a list of object names, so `status` can name a
   missing object on any machine.

Decided as each branch reaches them: the library input name (`kix` or
`kixpkgs`), a tag or a bare URL in `flake.nix`, whether `plan` prints JSON,
gc retention in configuration, removing `migrate domain` in 0.11.
