#!/usr/bin/env bash
# Verify behavioral parity between a Helm chart and a kix module.
#
# Usage:
#   ./scripts/verify-parity.sh <chart-name>                    # single default test
#   ./scripts/verify-parity.sh <chart-name> <helm-values-file> # single test with custom values
#   ./scripts/verify-parity.sh --all <chart-name>              # run all test cases from tests/<chart>/cases.txt
#
# Test cases live in tests/<chart-name>/cases.txt. Each line maps a flake
# package name to a Helm values file. This lets you test multiple configurations
# (e.g., defaults, sentinel mode, everything-enabled) in one invocation.
#
# Exit code 0 = all parity tests pass, 1 = differences found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Run all test cases for a chart ---
if [ "${1:-}" = "--all" ]; then
  CHART_NAME="${2:?Usage: verify-parity.sh --all <chart-name>}"
  CASES_FILE="$REPO_ROOT/tests/$CHART_NAME/cases.txt"

  if [ ! -f "$CASES_FILE" ]; then
    echo "ERROR: No test cases file at $CASES_FILE"
    echo "Create one with format: <flake-package> <helm-values-file>"
    exit 1
  fi

  total=0
  passed=0
  failed=0
  failed_names=()

  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Parse: <flake-package> <values-file>
    read -r pkg values_file <<< "$line"
    total=$((total + 1))

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║ Test case: $pkg"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Build values file path (relative to tests/<chart>/)
    VALUES_ARG=""
    if [ -n "$values_file" ] && [ "$values_file" != "-" ]; then
      VALUES_PATH="$REPO_ROOT/tests/$CHART_NAME/$values_file"
      if [ -f "$VALUES_PATH" ]; then
        # Only pass non-empty values files to Helm
        if [ -s "$VALUES_PATH" ] && grep -qv '^\s*#' "$VALUES_PATH"; then
          VALUES_ARG="$VALUES_PATH"
        fi
      else
        echo "WARNING: Values file not found: $VALUES_PATH"
      fi
    fi

    if "$SCRIPT_DIR/verify-parity-one.sh" "$CHART_NAME" "$pkg" "$VALUES_ARG"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      failed_names+=("$pkg")
    fi
  done < "$CASES_FILE"

  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "Results: $passed/$total passed, $failed failed"
  if [ $failed -gt 0 ]; then
    echo "Failed: ${failed_names[*]}"
    echo "═══════════════════════════════════════════════════════════════"
    exit 1
  fi
  echo "═══════════════════════════════════════════════════════════════"
  exit 0
fi

# --- Single test (backwards-compatible) ---
CHART_NAME="${1:?Usage: verify-parity.sh <chart-name> [helm-values-file]}"
VALUES_FILE="${2:-}"
FLAKE_PKG="$CHART_NAME"

exec "$SCRIPT_DIR/verify-parity-one.sh" "$CHART_NAME" "$FLAKE_PKG" "$VALUES_FILE"
