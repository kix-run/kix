# Build caches and disk

Claude Code loads this file together with `CLAUDE.md`. Other documents cite
it as `CLAUDE.md` § Build caches and disk.

Two failure modes here are invisible in the tool output, so a PreToolUse hook
guards each. Both live in `.claude/hooks/` and are wired up by
`.claude/settings.json`; both take `--check` so you can run them by hand.

**Never let build output sit inside the checkout.** A `path:` flakeref copies
a directory into the Nix store with no filtering at all: `.gitignore` is not
consulted, `.git` goes in too, and a fresh copy is made every time any byte of
the tree changes. On 9 Sep 2026 that left two `-source` paths of 47.7 GB and
48.4 GB in the store against a 40 MB git-filtered tree of the same commit, and
filled a 1.9 TB disk overnight. The bulk was `.claude/worktrees/` (30 GB) and
cargo target dirs (16 GB). Nothing in the Nix output names the cause.

`nix_store_guard.py` measures the gitignored bytes a `path:` copy would drag in
and refuses past 2 GB, and refuses any Nix command with under 12 GB free on the
store volume, except `nix store gc`, `delete`, and `optimise`, which free space. The remedy it prints is usually to drop the `path:` prefix, since
a plain directory makes Nix use the git fetcher, which skips gitignored files.
Note that the git fetcher also skips untracked files, so `git add` anything new
the evaluation must see.

`devenv.nix` keeps its cargo target dir under `$XDG_CACHE_HOME`, keyed on the
checkout path, for the same reason. Do not move it back into the tree. If you
add another build cache, put it outside the checkout or gitignore it and expect
the guard to shout.

**`target/debug/deps` is flat and cargo never prunes it.** Past roughly 150k
entries every rustc in the build stalls on path lookups, and it does not look
like a slow build, it looks like an idle machine (upstream
rust-lang/cargo#16665, no fix). `cargo_target_guard.py` counts the entries
before any compiling cargo subcommand and refuses at that point. The fix is to
delete the target dir and pay one cold rebuild. Do not repoint
`CARGO_TARGET_DIR` to dodge it; that just starts a second pile.

Keep git worktrees outside the repo. `.claude/worktrees/` is gitignored, which
hides it from git and from nothing else.
