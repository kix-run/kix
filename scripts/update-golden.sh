#!/usr/bin/env bash
# Update golden files for snapshot testing.
#
# Usage:
#   ./scripts/update-golden.sh          # update all variants
#   ./scripts/update-golden.sh coredns  # update one variant
#
# Golden files live in tests/<variant>/golden/*.json.
# After updating, review the diff with `git diff tests/` before committing.

set -euo pipefail

cd "$(dirname "$0")/.."

# All chart variants from flake.nix (must be kept in sync).
# To discover variants programmatically:
#   nix eval .#packages.aarch64-darwin --apply 'builtins.attrNames' --json | jq -r '.[]'
ALL_VARIANTS=(
  coredns coredns-prometheus coredns-serviceaccount coredns-pdb coredns-hpa coredns-autoscaler
  valkey valkey-sentinel valkey-full valkey-podmonitor valkey-prometheusrule valkey-hpa valkey-hpa-sentinel
  cert-manager cert-manager-no-cainjector cert-manager-no-startupapicheck
  cluster-example
)

variants=("${@:-${ALL_VARIANTS[@]}}")

for variant in "${variants[@]}"; do
  echo "==> Updating golden files for: $variant"

  # Build the variant
  result=$(nix build ".#${variant}" --no-link --print-out-paths 2>/dev/null)

  # Create golden directory
  golden_dir="tests/${variant}/golden"
  mkdir -p "$golden_dir"

  # Remove old golden files (catches renames/removals)
  rm -f "$golden_dir"/*.json

  # Copy and normalize each manifest.
  # jq -S sorts keys for deterministic output.
  for f in "$result"/*.json; do
    base=$(basename "$f")
    jq -S '.' "$f" > "$golden_dir/$base"
  done

  echo "    $(ls "$golden_dir" | wc -l | tr -d ' ') golden files written"
done

echo ""
echo "Done. Review changes with: git diff tests/"
