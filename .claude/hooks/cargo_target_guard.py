#!/usr/bin/env python3
"""Refuse to build when the cargo target directory has bloated.

`target/debug/deps` is a FLAT directory. Cargo never garbage-collects it, so a
shared target dir accumulates one set of artifacts per worktree path forever,
and every rustc invocation pays path-lookup cost across the whole thing. This
is upstream bug rust-lang/cargo#16665, which has no fix.

MEASURED in the Lithus monorepo, 30 Aug 2026, same commit, same machine, quiet.
A frozen record of one experiment, not a claim about this repo's current state;
what transfers is the shape, not the absolute numbers:

    deps/ entries    cold build of a fresh worktree
        42,784       146 s     (a private target dir, one worktree's worth)
       781,297       265 s     (the shared dir, five worktrees of history)

The processes look busy and are not: at 781k entries each of the fifteen
parallel rustc's sat at ~18% of one core, and the build spent more time in the
kernel (545 s sys) than in userspace (353 s user). Nothing in the build output
says "your target directory is why this is slow", which is exactly why this
guard exists. The failure mode is invisible and everyone re-derives it.

THE CHECK IS FREE. On APFS a directory's st_size is exactly 32 bytes per
entry, so one stat() gives the count. An honest `ls | wc -l` on a bloated
deps/ takes 3.4 s; this takes microseconds, so it can run before every build.

Two modes:
    (no args)   PreToolUse(Bash) hook, reads the payload on stdin.
    --check     CLI, for a shell or CI check. Exit 1 means too big.
"""

# The system python3 on macOS is 3.9; `str | None` in an annotation needs this.
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shlex
import sys

# APFS stores 32 bytes of directory entry per file. Verified against exact
# counts at both ends of the range above (25009728/781297 and 1369088/42784
# are both exactly 32.0).
BYTES_PER_ENTRY = 32

# Entry counts, not bytes. The cost is per-directory-entry lookups.
#
# The unit to think in is ONE complete build of the workspace. To measure it,
# empty the target dir, build once, and read the count out of `--check`. On
# 10 Sep 2026 a full `cargo test` build of the kix workspace left 4,356
# entries, so the defaults below are roughly eleven and thirty-four builds'
# worth of accumulation.
#
# That multiplier is a POLICY CHOICE, not a measured cliff, since the cost
# rises smoothly and nobody has mapped the curve. Bias low. The two mistakes
# are not symmetric: refusing too early costs one cold rebuild, refusing too
# late taxes every build, for everyone, for days, invisibly.
#
# Override either with the matching environment variable.
DEFAULT_WARN_ENTRIES = 50_000
DEFAULT_DENY_ENTRIES = 150_000

# Cargo subcommands that actually compile. `cargo fmt`, `cargo tree` and
# friends do not touch deps/, so they are not worth interrupting.
COMPILING = {"build", "test", "nextest", "clippy", "check", "run", "bench", "doc"}

# Shell operators that start a fresh command, so each segment can be checked
# for what sits in COMMAND position. Without this, `echo "cargo build is slow"`
# reads as a build and gets refused, and a guard that cries wolf gets disabled.
SEPARATORS = re.compile(r"(?:\|\||&&|[;\n|&()])")

# Tokens that may legitimately precede `cargo`: a leading VAR=value assignment,
# or a wrapper that execs what follows.
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"sudo", "env", "time", "nice", "nohup", "command", "exec"}


def is_compiling(command: str) -> bool:
    """True when some segment really invokes a cargo subcommand that builds."""
    for segment in SEPARATORS.split(command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = segment.split()
        # Step over `FOO=bar`, `env`, `sudo` and friends to whatever is run.
        while tokens and (ASSIGNMENT.match(tokens[0]) or tokens[0] in WRAPPERS):
            tokens.pop(0)
        if not tokens or pathlib.PurePath(tokens[0]).name != "cargo":
            continue
        # `cargo +nightly test`: skip the toolchain and any global flag.
        rest = [t for t in tokens[1:] if not t.startswith(("+", "-"))]
        if rest and rest[0] in COMPILING:
            return True
    return False


def project_root() -> pathlib.Path:
    return pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())


def threshold(key: str, fallback: int) -> int:
    """Env wins, then the shared default.

    Every repo's unit is different, and it grows as a workspace does, so a
    machine that builds differently can move the bounds without editing this.
    """
    raw = os.environ.get(key)
    return int(raw) if raw else fallback


WARN_ENTRIES = threshold("CARGO_TARGET_WARN_ENTRIES", DEFAULT_WARN_ENTRIES)
DENY_ENTRIES = threshold("CARGO_TARGET_DENY_ENTRIES", DEFAULT_DENY_ENTRIES)


def devenv_target_dir(project: pathlib.Path) -> str:
    """Where `devenv.nix` points CARGO_TARGET_DIR for this checkout.

    A PreToolUse hook does not inherit the devenv shell's environment, so
    without recomputing this the guard would see nothing at all whenever
    Claude was started outside `devenv shell`. Keep the two in step: this
    mirrors `targetDirKey` and the `enterShell` export in devenv.nix, and
    `builtins.hashString "sha256"` is a plain hex sha256 of the string.
    """
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    key = hashlib.sha256(str(project).encode()).hexdigest()[:12]
    return f"{cache}/kix-cargo-target/{project.name}-{key}"


def deps_dirs() -> list[pathlib.Path]:
    """Every target dir this repo might be using, in priority order.

    `cli/target` is a host rustup toolchain's; `cli/target-devenv` is where
    devenv used to point before the dir moved out of the checkout, and is
    still what the worktrees under `.claude/worktrees/` carry.
    """
    seen: list[pathlib.Path] = []
    project = project_root()
    candidates = [
        os.environ.get("CARGO_TARGET_DIR"),
        devenv_target_dir(project),
        str(project / "cli/target"),
        str(project / "cli/target-devenv"),
    ]
    for raw in candidates:
        if not raw:
            continue
        deps = pathlib.Path(raw).expanduser() / "debug" / "deps"
        if deps.is_dir() and deps not in seen:
            seen.append(deps)
    return seen


def entries(deps: pathlib.Path) -> int:
    """Count directory entries. O(1) on APFS, an honest walk elsewhere."""
    if sys.platform == "darwin":
        return deps.stat().st_size // BYTES_PER_ENTRY
    # Linux directory sizes are block-rounded and tell us nothing, so count
    # for real. CI runners start from an empty cache, so this rarely fires.
    return sum(1 for _ in deps.iterdir())


def worst() -> tuple[pathlib.Path, int] | None:
    """The fullest target dir in play, which is the one that will hurt."""
    found = [(d, entries(d)) for d in deps_dirs()]
    return max(found, key=lambda t: t[1]) if found else None


def remedy(deps: pathlib.Path) -> str:
    target = deps.parent.parent
    return (
        f"Delete {target} and re-run the command. That costs one cold rebuild, "
        f"which is the point: you are paying more than that already, spread "
        f"across every build. Do not work around it by pointing "
        f"CARGO_TARGET_DIR somewhere else; that just starts a second pile."
    )


def main() -> int:
    check_mode = "--check" in sys.argv[1:]

    if not check_mode:
        # Hook mode. Anything unparseable means "no opinion". A guard must
        # never be the reason a build cannot start.
        try:
            payload = json.load(sys.stdin)
        except (json.JSONDecodeError, ValueError):
            return 0
        command = (payload.get("tool_input") or {}).get("command") or ""
        if not is_compiling(command):
            return 0

    found = worst()
    if found is None:
        if check_mode:
            print("cargo target dir: none built yet, nothing to check.")
        return 0

    deps, count = found
    if count >= DENY_ENTRIES:
        reason = (
            f"The cargo target directory has bloated: {count:,} entries in "
            f"{deps} (limit {DENY_ENTRIES:,}). deps/ is a flat directory that "
            f"cargo never prunes, and past this size every rustc in the build "
            f"stalls on path lookups. It does not look like a slow build, it "
            f"looks like an idle machine: the rustc processes sit at a fraction "
            f"of a core each and the build spends more time in the kernel than "
            f"in userspace. Upstream bug rust-lang/cargo#16665, no fix. " + remedy(deps)
        )
        if check_mode:
            print(reason, file=sys.stderr)
            return 1
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": reason,
                    }
                }
            )
        )
        return 0

    if count >= WARN_ENTRIES:
        note = (
            f"cargo target dir is filling up: {count:,} entries in {deps} "
            f"(builds are refused at {DENY_ENTRIES:,}). Builds are already "
            f"slower than they need to be. {remedy(deps)}"
        )
        if check_mode:
            print(note)
            return 0
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "additionalContext": note,
                    },
                    "systemMessage": note,
                }
            )
        )
        return 0

    if check_mode:
        print(
            f"cargo target dir: {count:,} entries in {deps}, healthy "
            f"(warn {WARN_ENTRIES:,}, refuse {DENY_ENTRIES:,})."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
