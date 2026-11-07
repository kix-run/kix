#!/usr/bin/env bash
# Check the `nix` builder with an unpacked Kix release archive on a machine
# that has Nix installed, as a user the Nix daemon does not trust.
#
# usage: cli/runtime/nix-builder.sh <unpacked-archive> <kixpkgs-checkout>
#
# 1. The repository's Helm cluster builds to the same YAML under the `kix`
#    builder and the `nix` builder.
# 2. A new project with `builder = "nix"` in kix.toml:
#    - stops with the "not visible to Nix" error while kix.toml is untracked,
#    - builds with `kix build` once git tracks it, to the same YAML as 1,
#    - builds `.#cluster-<name>-activation` with plain `nix build`.
#
# <kixpkgs-checkout> must be a git clone. The project takes the Kix library
# from it and nixpkgs from its flake.lock.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  sed -n '5p' "$0" >&2
  exit 2
fi

archive="$(cd "$1" && pwd -P)"
repo="$(cd "$2" && pwd -P)"
kix="$archive/bin/kix"

if [[ ! -x "$kix" || ! -f "$archive/libexec/kix/manifest.json" ]]; then
  echo "$archive does not hold bin/kix and libexec/kix/manifest.json" >&2
  exit 2
fi
if [[ ! -d "$repo/.git" ]]; then
  echo "$repo is not a git clone (a worktree's .git file points outside it)" >&2
  exit 2
fi

trusted="$(nix --extra-experimental-features nix-command store info --json | python3 -c 'import json, sys; print(json.load(sys.stdin).get("trusted"))')"
if [[ "$trusted" != "False" ]]; then
  echo "the Nix daemon trusts this user (trusted: $trusted), so this check proves nothing" >&2
  exit 1
fi

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

echo "== the repository's Helm cluster under both builders"
(cd "$repo" && KIX_TEST_BUILDER=kix "$kix" --no-color build helm >"$tmp/kix.yaml")
(cd "$repo" && KIX_TEST_BUILDER=nix "$kix" --no-color build helm >"$tmp/nix.yaml")
grep -q "^kind:" "$tmp/kix.yaml"
if ! cmp -s "$tmp/kix.yaml" "$tmp/nix.yaml"; then
  echo "the kix and nix builders built different YAML for the helm cluster:" >&2
  diff -u "$tmp/kix.yaml" "$tmp/nix.yaml" >&2 || true
  exit 1
fi
echo "identical ($(grep -c "^kind:" "$tmp/kix.yaml") objects)"

echo "== a project with builder = \"nix\""
nixpkgs="$(python3 - "$repo/flake.lock" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
node = lock["nodes"][lock["nodes"]["root"]["inputs"]["nixpkgs"]]["locked"]
print(f"github:{node['owner']}/{node['repo']}/{node['rev']}")
EOF
)"
proj="$tmp/proj"
mkdir -p "$proj"
cp -R "$repo/tests/helm-test-chart" "$proj/helm-test-chart"
sed 's|\.\./tests/helm-test-chart|./helm-test-chart|' "$repo/clusters/test-helm.nix" >"$proj/cluster.nix"
cat >"$proj/flake.nix" <<EOF
{
  inputs = {
    nixpkgs.url = "$nixpkgs";
    kix.url = "git+file://$repo?dir=kix";
  };
  outputs =
    inputs:
    inputs.kix.lib.mkFlake {
      inherit inputs;
      clusters.helm = ./cluster.nix;
    };
}
EOF
echo 'builder = "nix"' >"$proj/kix.toml"
cd "$proj"
git init -q
git add flake.nix cluster.nix helm-test-chart

if "$kix" --no-color build helm >"$tmp/untracked.yaml" 2>"$tmp/untracked.err"; then
  echo "kix build succeeded although Nix cannot see kix.toml" >&2
  exit 1
fi
if ! grep -q "git add kix.toml" "$tmp/untracked.err"; then
  echo "an untracked kix.toml gave the wrong error:" >&2
  cat "$tmp/untracked.err" >&2
  exit 1
fi
echo "untracked kix.toml: refused with the git add hint"

git add kix.toml
"$kix" doctor
"$kix" --no-color build helm >"$tmp/project.yaml"
if ! cmp -s "$tmp/kix.yaml" "$tmp/project.yaml"; then
  echo "the project built different YAML from the repository's helm cluster:" >&2
  diff -u "$tmp/kix.yaml" "$tmp/project.yaml" >&2 || true
  exit 1
fi
echo "kix build: identical to the kix builder"

nix build --extra-experimental-features "nix-command flakes pipe-operators" --no-link --print-out-paths ".#cluster-helm-activation" >"$tmp/activation.path"
test -e "$(cat "$tmp/activation.path")/activation"
echo "nix build .#cluster-helm-activation: $(cat "$tmp/activation.path")"
