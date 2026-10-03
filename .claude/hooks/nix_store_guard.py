#!/usr/bin/env python3
"""Refuse a Nix command that would copy this repo's build output into the store.

Nix has two ways to read a local directory as a flake, and they behave very
differently:

    nix build ./docs#site                 git fetcher, skips gitignored files
    nix build --override-input k path:.   path fetcher, copies EVERYTHING

The `path:` scheme does no filtering at all. Point it at this repo and Nix
copies `cli/target`, `cli/target-devenv`, `docs/node_modules` and every
`.claude/worktrees/*` checkout into the store, as one immutable object, on
every invocation where any byte of the tree changed.

MEASURED here on 9 Sep 2026. Two such copies were still resident the next
morning, at 47.7 GB and 48.4 GB, against a 40 MB git-filtered tree of the same
commit. A 1.9 TB disk reached 100% overnight and OrbStack died twice. Nothing
in the Nix output names the cause: it looks like a slow evaluation, and the
store path it produces looks like every other `-source`.

So this guard measures what a `path:` copy would actually drag in, and refuses
before the copy happens. It also declines to start any Nix command when the
store volume is nearly full, because a half-written store path is a worse
place to discover that than a refusal is.

Two modes:
    (no args)   PreToolUse(Bash) hook, reads the payload on stdin.
    --check     CLI, for a shell or CI check. Exit 1 means refuse.
"""

# The system python3 on macOS is 3.9; `str | None` in an annotation needs this.
from __future__ import annotations

import json
import os
import pathlib
import re
import shlex
import subprocess
import sys

KIB = 1024
MIB = KIB * KIB
GIB = MIB * KIB

# Gitignored bytes under a tree that a `path:` flakeref would copy verbatim.
#
# Warn is "you are about to pay for this"; deny is "this is the failure mode
# that filled the disk". Both are POLICY, not a measured cliff: the cost is
# linear in bytes, and the only sharp edge is the one at the end of the disk.
# Bias low. Refusing costs one edited command; not refusing cost a night.
DEFAULT_WARN_BULK = 256 * MIB
DEFAULT_DENY_BULK = 2 * GIB

# Free space on the store volume below which a Nix command is a bad idea.
DEFAULT_WARN_FREE = 40 * GIB
DEFAULT_DENY_FREE = 12 * GIB

# Commands that can copy a tree into the store. `nix-instantiate` and friends
# can too, but the flakes-era commands are the ones used here.
NIX_COMMANDS = {"nix", "nix-build", "nix-shell", "nix-instantiate"}

# Shell operators that start a fresh command, so each segment is checked for
# what sits in COMMAND position. Without this, `echo "use path: for nix"`
# reads as a build and gets refused, and a guard that cries wolf gets disabled.
SEPARATORS = re.compile(r"(?:\|\||&&|[;\n|&()])")

# Tokens that may legitimately precede the command: a leading VAR=value
# assignment, or a wrapper that execs what follows.
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
WRAPPERS = {"sudo", "env", "time", "nice", "nohup", "command", "exec", "timeout"}

# A `path:` flakeref, with or without the `?query#attr` tail that Nix allows.
PATH_REF = re.compile(r"\bpath:([^\s\"'#?]+)")


def segments(command: str) -> list[list[str]]:
    """Split a command line into argv lists, one per shell segment."""
    out = []
    for segment in SEPARATORS.split(command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = segment.split()
        while tokens and (ASSIGNMENT.match(tokens[0]) or tokens[0] in WRAPPERS):
            tokens.pop(0)
        if tokens:
            out.append(tokens)
    return out


def nix_segments(command: str) -> list[list[str]]:
    """The segments that actually invoke Nix."""
    return [t for t in segments(command) if pathlib.PurePath(t[0]).name in NIX_COMMANDS]


# `nix store <sub>` commands that free space. The free-space refusal names
# `nix store gc` as the remedy, so it must not refuse the remedy itself.
RECLAIM_SUBCOMMANDS = {"gc", "delete", "optimise"}


def reclaims_only(command: str) -> bool:
    """Whether every Nix segment of `command` frees store space."""
    nix = nix_segments(command)
    return bool(nix) and all(
        len(t) >= 3 and t[1] == "store" and t[2] in RECLAIM_SUBCOMMANDS for t in nix
    )


def project_root() -> pathlib.Path:
    return pathlib.Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())


def limit(key: str, fallback: int) -> int:
    raw = os.environ.get(key)
    return int(raw) if raw else fallback


WARN_BULK = limit("NIX_GUARD_WARN_BULK_BYTES", DEFAULT_WARN_BULK)
DENY_BULK = limit("NIX_GUARD_DENY_BULK_BYTES", DEFAULT_DENY_BULK)
WARN_FREE = limit("NIX_GUARD_WARN_FREE_BYTES", DEFAULT_WARN_FREE)
DENY_FREE = limit("NIX_GUARD_DENY_FREE_BYTES", DEFAULT_DENY_FREE)


def human(size: int) -> str:
    if size >= GIB:
        return f"{size / GIB:.1f} GB"
    if size >= MIB:
        return f"{size / MIB:.0f} MB"
    return f"{size / KIB:.0f} KB"


def free_bytes() -> int | None:
    """Free space on the volume holding the Nix store."""
    try:
        stat = os.statvfs("/nix/store")
    except OSError:
        return None
    return stat.f_bavail * stat.f_frsize


def path_refs(command: str) -> list[pathlib.Path]:
    """Directories a `path:` flakeref in this command would copy verbatim.

    Store paths are already immutable and already filtered, so they are
    exactly the case this guard must stay out of the way of: the capture
    pipeline passes `--override-input kixpkgs path:/nix/store/...` on every
    documented command it runs.
    """
    found: list[pathlib.Path] = []
    root = project_root()
    for raw in PATH_REF.findall(command):
        resolved = pathlib.Path(os.path.expanduser(raw))
        if not resolved.is_absolute():
            resolved = root / resolved
        try:
            resolved = resolved.resolve()
        except OSError:
            continue
        if str(resolved).startswith("/nix/store"):
            continue
        if resolved.is_dir() and resolved not in found:
            found.append(resolved)
    return found


def git_root(path: pathlib.Path) -> pathlib.Path | None:
    """The working tree `path` sits in, which is what Nix would copy."""
    try:
        out = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return pathlib.Path(out.stdout.strip()) if out.returncode == 0 else None


def ignored_bulk(root: pathlib.Path) -> list[tuple[str, int]]:
    """Gitignored paths under `root` and their sizes, largest first.

    `--ignored=traditional` collapses a wholly ignored directory to one entry,
    which keeps this to a few dozen `du` calls rather than a walk of every
    artifact. The whole check runs in well under a second on a warm cache.
    """
    try:
        listing = subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain", "--ignored=traditional"],
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if listing.returncode != 0:
        return []

    candidates = [
        line[3:].strip().strip('"')
        for line in listing.stdout.splitlines()
        if line.startswith("!! ")
    ]
    if not candidates:
        return []

    sizes: list[tuple[str, int]] = []
    try:
        measured = subprocess.run(
            ["du", "-sk", "--"] + candidates,
            cwd=str(root),
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    for line in measured.stdout.splitlines():
        parts = line.split("\t", 1)
        if len(parts) == 2 and parts[0].strip().isdigit():
            sizes.append((parts[1].strip(), int(parts[0]) * KIB))
    sizes.sort(key=lambda item: item[1], reverse=True)
    return sizes


def bulk_remedy(root: pathlib.Path, worst: list[tuple[str, int]]) -> str:
    named = ", ".join(f"{name} {human(size)}" for name, size in worst[:3])
    return (
        f"Biggest contributors: {named}. Either drop the `path:` prefix so the "
        f"flakeref reads as a plain directory, which makes Nix use the git "
        f"fetcher and skip everything listed in .gitignore, or delete the "
        f"build output above first. Note that the git fetcher also skips "
        f"untracked files, so `git add` anything new the evaluation must see. "
        f"Tree: {root}"
    )


def findings(command: str | None) -> tuple[str | None, str | None]:
    """Return (deny_reason, warn_note). At most one of the two is set."""
    free = free_bytes()
    if command is not None and reclaims_only(command):
        return (None, None)
    if free is not None and free < DENY_FREE:
        return (
            f"Only {human(free)} free on the Nix store volume (refusing below "
            f"{human(DENY_FREE)}). A Nix build that runs out of space part way "
            f"leaves a partial store path and an unhelpful error. Reclaim "
            f"first: `nix store gc` drops everything unreachable from a GC "
            f"root, and `nix store gc --max 50G` bounds how long that takes.",
            None,
        )

    if command is not None:
        for ref in path_refs(command):
            root = git_root(ref) or ref
            sizes = ignored_bulk(root)
            total = sum(size for _, size in sizes)
            if total >= DENY_BULK:
                return (
                    f"This command passes `path:{ref}`, and the `path:` scheme "
                    f"copies a directory into the store with no filtering at "
                    f"all. That tree currently holds {human(total)} of "
                    f"gitignored build output, so the copy would be at least "
                    f"that large, and Nix makes a fresh one every time the "
                    f"tree changes. " + bulk_remedy(root, sizes),
                    None,
                )
            if total >= WARN_BULK:
                return (
                    None,
                    f"`path:{ref}` copies the tree unfiltered, including "
                    f"{human(total)} of gitignored build output (refused at "
                    f"{human(DENY_BULK)}). " + bulk_remedy(root, sizes),
                )

    if free is not None and free < WARN_FREE:
        return (
            None,
            f"{human(free)} free on the Nix store volume (Nix commands are "
            f"refused below {human(DENY_FREE)}). `nix store gc --max 50G` "
            f"reclaims a bounded amount without a full sweep.",
        )

    return (None, None)


def main() -> int:
    check_mode = "--check" in sys.argv[1:]
    command: str | None = None

    if not check_mode:
        # Hook mode. Anything unparseable means "no opinion". A guard must
        # never be the reason a build cannot start.
        try:
            payload = json.load(sys.stdin)
        except (json.JSONDecodeError, ValueError):
            return 0
        command = (payload.get("tool_input") or {}).get("command") or ""
        if not nix_segments(command):
            return 0
    else:
        rest = [a for a in sys.argv[1:] if a != "--check"]
        command = " ".join(rest) if rest else None

    deny, warn = findings(command)

    if deny:
        if check_mode:
            print(deny, file=sys.stderr)
            return 1
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": deny,
                    }
                }
            )
        )
        return 0

    if warn:
        if check_mode:
            print(warn)
            return 0
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "additionalContext": warn,
                    },
                    "systemMessage": warn,
                }
            )
        )
        return 0

    if check_mode:
        free = free_bytes()
        where = (
            f"{human(free)} free on the Nix store volume"
            if free
            else "store volume unknown"
        )
        print(f"nix store guard: {where}, nothing to flag.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
