#!/usr/bin/env bash
# Prepare an older release's checkout so its docs build and match the
# current site. pages.yml runs it on each release checkout before it builds
# that release's docs. It does two things:
#
# 1. Copies this checkout's docs theme over the release: the stylesheet,
#    the code colour theme, and the layout components. Page content,
#    command output, snippets, the sidebar, and the llms.txt integration
#    stay as the release shipped them. Every theme file must work with the
#    oldest release that has docs (0.5). A theme change that needs a new
#    import breaks the release builds, and the deploy fails before it
#    publishes anything.
#
# 2. Adds the snippets in docs/release-compat/snippets that a release's
#    pages import but its rewritten history no longer contains. 0.5 to 0.7
#    took one snippet from a cluster the history rewrite removed. A snippet
#    the release already builds is left alone.
#
# Usage: prepare-release-docs.sh <release checkout root>
#        prepare-release-docs.sh --list
set -euo pipefail

theme=(
  docs/src/styles/kix.css
  docs/src/lib/kix-night.theme.json
  docs/src/components/Header.astro
  docs/src/components/PageTitle.astro
  docs/src/components/SiteTitle.astro
  docs/src/components/TwoColumnContent.astro
)

root=$(cd "$(dirname "$0")/../.." && pwd)
compat=docs/release-compat/snippets

if [ "${1:-}" = --list ]; then
  printf '%s\n' "${theme[@]}"
  (cd "$root" && find "$compat" -type f | sort)
  exit 0
fi

dest=${1:?usage: prepare-release-docs.sh <release checkout root>}
for f in "${theme[@]}"; do
  [ -f "$dest/$f" ] || { echo "$dest has no $f to replace" >&2; exit 1; }
  cp "$root/$f" "$dest/$f"
done

# The docs build copies its generated snippets into src/snippets/ without
# deleting what is there, so a file placed here first survives. The docs
# flake reads the checkout through Git, which skips untracked and ignored
# files, so each one is added to the release checkout's index.
(cd "$root/$compat" && find . -type f) | while read -r f; do
  target="$dest/docs/src/snippets/${f#./}"
  mkdir -p "$(dirname "$target")"
  cp "$root/$compat/${f#./}" "$target"
  git -C "$dest" add --force "docs/src/snippets/${f#./}"
done
