#!/usr/bin/env bash
# Write a cluster's manifests as the directory the `cluster-<name>` flake
# package holds (`<namespace>/<name>-<kind>.yaml`), from what `kix build`
# prints.
#
# Plain Nix cannot render a Helm chart, so `nix build .#cluster-<name>` fails
# for a cluster that uses Helm. This script renders through `kix` and then
# writes the directory with the same code, `mkManifests` in kix/lib.
#
# usage: scripts/kix-manifests.sh <flake-dir> <cluster> <out-link>
#
# The script picks which Kix renders the cluster:
#
# - KIX, when set, names the `kix` command to run.
# - A project whose `kix.toml` sets `library = "self"` (the Kix repository)
#   runs the Kix its own flake builds, `nix run <flake-dir>#kix`. A released
#   Kix would pair its own binary with this checkout's library, and an older
#   one refuses the `library` key.
# - Any other project runs `kix` on PATH, which runs the Kix version the
#   project's `flake.lock` names.

set -euo pipefail

if [[ $# -ne 3 ]]; then
  sed -n '10p' "$0" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flake="$1"
cluster="$2"
out="$3"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ -n "${KIX:-}" ]]; then
  kix=("$KIX")
elif grep -Eqs '^[[:space:]]*library[[:space:]]*=[[:space:]]*"self"' "$flake/kix.toml"; then
  kix=(nix run --extra-experimental-features 'nix-command flakes pipe-operators' "$(cd "$flake" && pwd)#kix" --)
else
  kix=(kix)
fi

"${kix[@]}" --flake "$flake" --quiet build -o json "$cluster" >"$tmp/manifests.json"

nix build --out-link "$out" --impure \
  --extra-experimental-features 'nix-command flakes pipe-operators' \
  --expr "
    let
      flake = builtins.getFlake \"git+file://$REPO_ROOT\";
      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
      kix = import $REPO_ROOT/kix/lib { inherit pkgs; inherit (pkgs) lib; };
    in
    kix.mkManifests {
      name = \"$cluster\";
      rawManifests = builtins.fromJSON (builtins.readFile $tmp/manifests.json);
    }"
