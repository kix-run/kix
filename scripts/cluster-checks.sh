#!/usr/bin/env bash
# Run the schema and alert-rule checks of one cluster on the manifests that
# `kix build` writes.
#
# The flake checks `schema-cluster-<name>` and `rules-cluster-<name>` take
# their manifests from a plain Nix build, and plain Nix cannot render a Helm
# chart. This script takes the manifests from `kix` instead, so it also runs
# the checks of a cluster that uses Helm. It runs the same check code,
# kix/checks.nix.
#
# usage: scripts/cluster-checks.sh <flake-dir> <cluster> [<rules-test.yaml>]
#
#   scripts/cluster-checks.sh clusters cnpg clusters/test-cnpg.rules-test.yaml
#
# Set KIX to the `kix` command to run (default: `kix` on PATH).

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  sed -n '11,13p' "$0" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flake="$1"
cluster="$2"
tests="null"
if [[ $# -eq 3 ]]; then
  tests="$(realpath "$3")"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$REPO_ROOT/scripts/kix-manifests.sh" "$flake" "$cluster" "$tmp/manifests"

nix build --no-link --print-out-paths --impure \
  --extra-experimental-features 'nix-command flakes pipe-operators' \
  --expr "
    let
      flake = builtins.getFlake \"git+file://$REPO_ROOT\";
      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
      checks = import $REPO_ROOT/kix/checks.nix { inherit pkgs; inherit (pkgs) lib; };
      manifests = builtins.storePath \"$(readlink -f "$tmp/manifests")\";
    in
    [
      (checks.schemaCheck \"cluster-$cluster\" manifests)
      (checks.rulesCheck \"cluster-$cluster\" manifests $tests)
    ]"
