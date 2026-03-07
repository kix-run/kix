#!/usr/bin/env bash
# Verify behavioral parity between a Helm chart and a kix module.
#
# Usage: ./scripts/verify-parity.sh <chart-name> [helm-values-file]
#
# This script:
# 1. Renders the Helm chart with `helm template`
# 2. Builds the kix module with `nix build`
# 3. Normalizes both outputs (strips cosmetic differences)
# 4. Compares resources by kind, checking behavioral equivalence
#
# Exit code 0 = parity achieved, 1 = differences found

set -euo pipefail

CHART_NAME="${1:?Usage: verify-parity.sh <chart-name> [helm-values-file]}"
VALUES_FILE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Verifying parity for: $CHART_NAME ==="

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
echo "Building kix module..."
# Capture stdout (the output path) separately from stderr (download/build logs).
# stderr goes to the terminal so the user sees build progress.
KIX_OUT=$(nix build "${REPO_ROOT}#${CHART_NAME}" --extra-experimental-features pipe-operators --no-link --print-out-paths) || {
  echo ""
  echo "ERROR: nix build failed for '${CHART_NAME}'."
  echo "Make sure the chart is wired into flake.nix packages."
  exit 1
}

# --- Step 3: Normalize and compare using Python ---
# We use nix-shell to get PyYAML, then run one self-contained Python script
# that handles all normalization and comparison logic. This avoids the quoting
# nightmares of embedding Python in bash with variable interpolation.

HELM_OUT="$HELM_OUT" KIX_OUT="$KIX_OUT" WORK_DIR="$WORK_DIR" \
  nix-shell -p python3Packages.pyyaml --run "python3 '$SCRIPT_DIR/verify-parity.py'"
