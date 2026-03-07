#!/usr/bin/env bash
# Run a single parity test: render Helm, build kix, normalize, compare.
#
# Usage: verify-parity-one.sh <chart-name> <flake-package> [helm-values-file]
#
# This is the inner loop called by verify-parity.sh. It handles one test case:
# one Helm rendering + one kix build + comparison.

set -euo pipefail

CHART_NAME="${1:?Usage: verify-parity-one.sh <chart-name> <flake-package> [helm-values-file]}"
FLAKE_PKG="${2:?Usage: verify-parity-one.sh <chart-name> <flake-package> [helm-values-file]}"
VALUES_FILE="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Verifying parity: $FLAKE_PKG ==="

# --- Step 1: Render Helm chart ---
HELM_OUT="$WORK_DIR/helm"
mkdir -p "$HELM_OUT"

HELM_ARGS=(template release-name)

if [ -d "/tmp/$CHART_NAME" ]; then
  HELM_ARGS+=("/tmp/$CHART_NAME")
elif [ -d "$REPO_ROOT/charts/$CHART_NAME" ]; then
  HELM_ARGS+=("$REPO_ROOT/charts/$CHART_NAME")
else
  HELM_ARGS+=("$CHART_NAME/$CHART_NAME")
fi

if [ -n "$VALUES_FILE" ]; then
  HELM_ARGS+=(-f "$VALUES_FILE")
fi

HELM_ARGS+=(--output-dir "$HELM_OUT")

echo "Running: helm ${HELM_ARGS[*]}"
helm "${HELM_ARGS[@]}" 2>/dev/null

# --- Step 2: Build kix module ---
echo "Building kix module ($FLAKE_PKG)..."
KIX_OUT=$(nix build "${REPO_ROOT}#${FLAKE_PKG}" --extra-experimental-features pipe-operators --no-link --print-out-paths) || {
  echo ""
  echo "ERROR: nix build failed for '${FLAKE_PKG}'."
  echo "Make sure the package is wired into flake.nix."
  exit 1
}

# --- Step 3: Normalize and compare using Python ---
HELM_OUT="$HELM_OUT" KIX_OUT="$KIX_OUT" WORK_DIR="$WORK_DIR" \
  nix-shell -p python3Packages.pyyaml --run "python3 '$SCRIPT_DIR/verify-parity.py'"
