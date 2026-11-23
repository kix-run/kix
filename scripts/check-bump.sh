#!/usr/bin/env bash
# Report whether a package version bump is complete.
#
# A version bump changes files outside the package: docs
# excerpts, unit tests that name a version, vendored CRDs. This script runs
# the checks that find them and prints one line for each. The output of
# each check goes to a log file, which a failing line names. Run it from
# the repository root after committing the bump.
#
# The script does not test the upgrade on a cluster. The kind deploy in the
# package-authoring skill covers that.
#
# usage: scripts/check-bump.sh <package-dir> <old-version> [<base-commit>]
#
#   package-dir   the package folder, such as kix/packages/stable/valkey
#   old-version   the version the package pinned before, such as 8.1.10
#   base-commit   the commit the branch started from. The default is the
#                 merge base with origin/main.
#
# Exit status: 0 when every check passes, 1 when one fails, 2 on a usage
# error.
set -uo pipefail

if [ $# -lt 2 ]; then
  sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
fi

cd "$(git rev-parse --show-toplevel)" || exit 2
pkgdir="${1%/}"
old="$2"
base="${3:-$(git merge-base HEAD origin/main)}"
logs="$(mktemp -d -t check-bump.XXXXXX)"
fail=0
nix=(nix --extra-experimental-features 'nix-command flakes pipe-operators')

if [ ! -d "$pkgdir" ]; then
  echo "check-bump: '$pkgdir' is not a folder in this repository." >&2
  exit 2
fi

say() { printf '%-6s %s\n' "$1" "$2"; }

# Paths that keep old versions and digests as a record: release history,
# problem logs, design notes, and recorded test fixtures. The docs' command
# output is left out too, because the release regenerates it.
history=(':!changes' ':!CHANGELOG.md' ':!housekeeping' ':!v2_discussions' ':!*/tests/fixtures/*' ':!docs/src/command-output')

# Run one check with its output in a log file, and print its last lines
# when it fails.
run() {
  local name="$1" log
  shift
  log="$logs/${name// /-}.log"
  if "$@" >"$log" 2>&1; then
    say ok "$name"
  else
    say FAIL "$name (full output: $log)"
    grep -vE '^(trace:|warning: Git tree)' "$log" | tail -8 | sed 's/^/         /'
    fail=1
  fi
}

if [ -z "$(git status --porcelain)" ]; then
  say ok "working tree is clean"
else
  say FAIL "working tree has uncommitted changes"
  git status --short | head -5 | sed 's/^/         /'
  fail=1
fi

if git diff --quiet "$base" HEAD -- "$pkgdir"; then
  say FAIL "$pkgdir has not changed since $base"
  fail=1
else
  say ok "package changed"
fi

# An image digest that the package dropped must not remain anywhere.
old_digests=$(git grep -hoE 'sha256:[0-9a-f]{64}' "$base" -- "$pkgdir" | sort -u)
new_digests=$(git grep -hoE 'sha256:[0-9a-f]{64}' HEAD -- "$pkgdir" | sort -u)
stale=0
for digest in $old_digests; do
  grep -qxF "$digest" <<<"$new_digests" && continue
  hits=$(git grep -lF "$digest" HEAD -- . "${history[@]}" | sed 's/^HEAD://')
  if [ -n "$hits" ]; then
    stale=1
    say FAIL "old image digest ${digest:0:19}... is still in:"
    sed 's/^/         /' <<<"$hits"
  fi
done
if [ "$stale" = 0 ]; then say ok "no old image digest remains"; else fail=1; fi

if git diff --name-only --diff-filter=A "$base" HEAD -- changes/ | grep -q .; then
  say ok "change record added"
else
  say FAIL "no new file under changes/"
  fail=1
fi
run "change records valid" scripts/change-records.py check

if [ -d "$pkgdir/crds" ] || [ -d "$pkgdir/rbac" ]; then
  if command -v uv >/dev/null; then uv=(uv); else uv=("${nix[@]}" shell nixpkgs#uv -c uv); fi
  run "vendored CRDs and roles current" "${uv[@]}" run --frozen scripts/vendor-crds.py --check
else
  say skip "vendored CRDs and roles (the package vendors none)"
fi

system=$("${nix[@]}" eval --impure --raw --expr builtins.currentSystem)
run "library tests" "${nix[@]}" build ".#checks.$system.kix-lib-tests" --no-link

# List the places that still name the old version. Each needs a decision,
# so the list does not fail the check. Lock files and vendored CRDs name
# versions of other software, and the CLI's snapshots hold no package.
left=$(git grep -nF "$old" HEAD -- . "${history[@]}" \
  ':!*.lock' ':!*/crds/*' ':!*.snap' | sed 's/^HEAD://' | cut -c1-160)
if [ -n "$left" ]; then
  say review "'$old' still appears in $(wc -l <<<"$left") place(s). Update each one, or say why it stays:"
  head -25 <<<"$left" | sed 's/^/         /'
else
  say ok "'$old' appears nowhere else"
fi

echo
if [ "$fail" = 0 ]; then
  echo "check-bump: PASS"
else
  echo "check-bump: FAIL"
fi
exit "$fail"
