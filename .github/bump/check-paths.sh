#!/usr/bin/env bash
# Refuse a bump whose commits change files outside the places a version bump
# may touch.
#
# The agent that writes a bump reads text from upstream, which can carry
# instructions meant for it. This check keeps such instructions from
# changing the workflows, the scripts CI runs, or the flake. The workflow
# runs a copy of this script taken from the base commit, so the commits it
# checks cannot change it.
#
# usage: check-paths.sh <base-commit> <package-dir>...
#
# Exit status: 0 when every changed path is allowed, 1 when one is not.
set -euo pipefail

base="$1"
shift

allowed=(
  'changes/*'
  'kix/lib/tests/*'
  'cli/kix-cli/tests/snapshots/*'
  'docs/src/content/docs/*'
  'ROADMAP.md'
  'housekeeping/*'
  '.claude/skills/*/SKILL.md'
)
for dir in "$@"; do
  allowed+=("${dir%/}/*")
done

refused=()
while IFS= read -r -d '' path; do
  ok=0
  for pattern in "${allowed[@]}"; do
    # shellcheck disable=SC2053 # match the pattern as a glob
    if [[ "$path" == $pattern ]]; then
      ok=1
      break
    fi
  done
  [ "$ok" = 1 ] || refused+=("$path")
done < <(git diff -z --name-only --no-renames "$base" HEAD)

if [ "${#refused[@]}" -gt 0 ]; then
  echo "check-paths: the bump changes files a version bump may not touch:"
  printf '  %s\n' "${refused[@]}"
  exit 1
fi
echo "check-paths: every changed file is in an allowed place"
