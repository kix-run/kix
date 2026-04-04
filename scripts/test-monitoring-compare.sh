#!/usr/bin/env bash
# test-monitoring-compare.sh — Structural comparison of Helm vs native monitoring stack.
#
# Builds both test clusters and compares:
#   1. Component coverage (operator, prometheus, alertmanager, grafana, node-exporter, kube-state-metrics)
#   2. CRD completeness (all monitoring.coreos.com CRDs present)
#   3. RBAC coverage (ClusterRoles, ClusterRoleBindings)
#   4. Resource type breakdown
#   5. Key functional resources (ServiceMonitors, PrometheusRules)
#
# Usage: ./scripts/test-monitoring-compare.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

HELM_OUT="result-monitoring-helm"
NATIVE_OUT="result-monitoring-native"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass=0
warn=0
fail=0

check_pass() { echo -e "  ${GREEN}✓${NC} $1"; pass=$((pass + 1)); }
check_warn() { echo -e "  ${YELLOW}⚠${NC} $1"; warn=$((warn + 1)); }
check_fail() { echo -e "  ${RED}✗${NC} $1"; fail=$((fail + 1)); }

# ── Build both clusters ─────────────────────────────────────────────────

echo -e "${BLUE}Building test clusters...${NC}"
nix build ".#cluster-monitoring-helm" --extra-experimental-features pipe-operators -o "$HELM_OUT" 2>/dev/null
nix build ".#cluster-monitoring-native" --extra-experimental-features pipe-operators -o "$NATIVE_OUT" 2>/dev/null
echo

# ── Helper: extract kind from YAML files ─────────────────────────────────

extract_kinds() {
    local dir="$1"
    find "$dir" -name '*.yaml' -exec grep -h '^kind:' {} \; | sed 's/kind: //' | sort
}

extract_kinds_counted() {
    extract_kinds "$1" | uniq -c | sort -rn
}

# ── 1. Component coverage ──────────────────────────────────────────────

echo -e "${BLUE}1. Component coverage${NC}"

# Check that the native stack has the key packages
for component in prometheus-operator prometheus-server alertmanager node-exporter kube-state-metrics grafana; do
    if ls "$NATIVE_OUT/monitoring-system/${component}-"* &>/dev/null; then
        check_pass "$component present in native"
    else
        check_fail "$component MISSING in native"
    fi
done
echo

# ── 2. CRD completeness ────────────────────────────────────────────────

echo -e "${BLUE}2. CRD completeness${NC}"

helm_crds=$(find "$HELM_OUT/_cluster" -name '*monitoring.coreos.com*customresourcedefinition*' 2>/dev/null | xargs -I{} basename {} | sed 's/-customresourcedefinition.yaml//' | sort)
native_crds=$(find "$NATIVE_OUT/_cluster" -name '*monitoring.coreos.com*customresourcedefinition*' 2>/dev/null | xargs -I{} basename {} | sed 's/-customresourcedefinition.yaml//' | sort)

# CRDs that the Helm chart defines
for crd in $helm_crds; do
    if echo "$native_crds" | grep -q "^${crd}$"; then
        check_pass "CRD $crd"
    else
        check_fail "CRD $crd missing in native"
    fi
done

# Extra CRDs in native (not a problem, just informational)
for crd in $native_crds; do
    if ! echo "$helm_crds" | grep -q "^${crd}$"; then
        check_warn "CRD $crd extra in native (not in Helm)"
    fi
done
echo

# ── 3. RBAC coverage ──────────────────────────────────────────────────

echo -e "${BLUE}3. RBAC coverage${NC}"

helm_roles=$(find "$HELM_OUT/_cluster" -name '*clusterrole.yaml' ! -name '*binding*' | wc -l)
native_roles=$(find "$NATIVE_OUT/_cluster" -name '*clusterrole.yaml' ! -name '*binding*' | wc -l)
echo -e "  Helm ClusterRoles: $helm_roles, Native ClusterRoles: $native_roles"

helm_bindings=$(find "$HELM_OUT/_cluster" -name '*clusterrolebinding*' | wc -l)
native_bindings=$(find "$NATIVE_OUT/_cluster" -name '*clusterrolebinding*' | wc -l)
echo -e "  Helm ClusterRoleBindings: $helm_bindings, Native ClusterRoleBindings: $native_bindings"

# Check each native component has RBAC
for component in prometheus-operator prometheus-server kube-state-metrics; do
    if ls "$NATIVE_OUT/_cluster/${component}-clusterrole.yaml" &>/dev/null; then
        check_pass "$component has ClusterRole"
    else
        check_fail "$component missing ClusterRole"
    fi
    if ls "$NATIVE_OUT/_cluster/${component}-clusterrolebinding.yaml" &>/dev/null; then
        check_pass "$component has ClusterRoleBinding"
    else
        check_fail "$component missing ClusterRoleBinding"
    fi
done
echo

# ── 4. Resource type breakdown ────────────────────────────────────────

echo -e "${BLUE}4. Resource type breakdown${NC}"
echo -e "  ${YELLOW}Helm chart:${NC}"
extract_kinds_counted "$HELM_OUT/monitoring-system" | while read -r count kind; do
    printf "    %3d %s\n" "$count" "$kind"
done

echo -e "  ${YELLOW}Native:${NC}"
extract_kinds_counted "$NATIVE_OUT/monitoring-system" | while read -r count kind; do
    printf "    %3d %s\n" "$count" "$kind"
done

echo -e "  ${YELLOW}Cluster-scoped (Helm):${NC}"
extract_kinds_counted "$HELM_OUT/_cluster" | while read -r count kind; do
    printf "    %3d %s\n" "$count" "$kind"
done

echo -e "  ${YELLOW}Cluster-scoped (Native):${NC}"
extract_kinds_counted "$NATIVE_OUT/_cluster" | while read -r count kind; do
    printf "    %3d %s\n" "$count" "$kind"
done
echo

# ── 5. Functional resources ──────────────────────────────────────────

echo -e "${BLUE}5. Functional resources${NC}"

# ServiceMonitors
helm_smons=$(find "$HELM_OUT/monitoring-system" -name '*servicemonitor*' 2>/dev/null | wc -l)
native_smons=$(find "$NATIVE_OUT/monitoring-system" -name '*servicemonitor*' 2>/dev/null | wc -l)
echo -e "  ServiceMonitors — Helm: $helm_smons, Native: $native_smons"
if [ "$native_smons" -gt 0 ]; then
    check_pass "Native has ServiceMonitors ($native_smons)"
    find "$NATIVE_OUT/monitoring-system" -name '*servicemonitor*' -exec basename {} \; | sed 's/^/      /'
else
    check_fail "Native has no ServiceMonitors"
fi

# PrometheusRules
helm_rules=$(find "$HELM_OUT/monitoring-system" -name '*prometheusrule*' 2>/dev/null | wc -l)
native_rules=$(find "$NATIVE_OUT/monitoring-system" -name '*prometheusrule*' 2>/dev/null | wc -l)
echo -e "  PrometheusRules — Helm: $helm_rules, Native: $native_rules"
if [ "$native_rules" -gt 0 ]; then
    check_pass "Native has PrometheusRules ($native_rules)"
    find "$NATIVE_OUT/monitoring-system" -name '*prometheusrule*' -exec basename {} \; | sed 's/^/      /'
else
    check_warn "Native has no PrometheusRules (Helm ships ${helm_rules})"
fi

# Prometheus CR (look for kind: Prometheus in monitoring-system, exclude CRDs)
if grep -rl '^kind: Prometheus$' "$NATIVE_OUT/monitoring-system/" 2>/dev/null | head -1 | grep -q .; then
    check_pass "Native has Prometheus CR (operator manages StatefulSet)"
else
    check_fail "Native missing Prometheus CR"
fi

# Alertmanager CR
if grep -rl '^kind: Alertmanager$' "$NATIVE_OUT/monitoring-system/" 2>/dev/null | head -1 | grep -q .; then
    check_pass "Native has Alertmanager CR"
else
    check_fail "Native missing Alertmanager CR"
fi

# DaemonSet (node-exporter)
if grep -rl '^kind: DaemonSet$' "$NATIVE_OUT/monitoring-system/" 2>/dev/null | head -1 | grep -q .; then
    check_pass "Native has DaemonSet (node-exporter)"
else
    check_fail "Native missing DaemonSet"
fi
echo

# ── 6. Key differences (intentional) ──────────────────────────────────

echo -e "${BLUE}6. Key differences (intentional)${NC}"

# Helm has recording rules & dashboards that native doesn't (yet)
helm_configmaps=$(find "$HELM_OUT/monitoring-system" -name '*configmap*' | wc -l)
native_configmaps=$(find "$NATIVE_OUT/monitoring-system" -name '*configmap*' | wc -l)
echo -e "  ConfigMaps — Helm: $helm_configmaps (includes dashboards), Native: $native_configmaps"

# Helm bundles many default rules
echo -e "  PrometheusRules — Helm ships ${helm_rules} default rule sets (kubernetes-apps, node-exporter, etc.)"
echo -e "  Native ships ${native_rules} (per-package rules via DI, more added as packages opt in)"

# The Helm chart creates its own Services; native creates explicit ones
helm_services=$(find "$HELM_OUT/monitoring-system" -name '*service.yaml' ! -name '*servicemonitor*' ! -name '*serviceaccount*' | wc -l)
native_services=$(find "$NATIVE_OUT/monitoring-system" -name '*service.yaml' ! -name '*servicemonitor*' ! -name '*serviceaccount*' | wc -l)
echo -e "  Services — Helm: $helm_services, Native: $native_services"
echo

# ── Summary ────────────────────────────────────────────────────────────

echo -e "${BLUE}Summary${NC}"
echo -e "  ${GREEN}Passed: $pass${NC}"
echo -e "  ${YELLOW}Warnings: $warn${NC}"
echo -e "  ${RED}Failed: $fail${NC}"
echo

if [ "$fail" -gt 0 ]; then
    echo -e "${RED}FAIL — $fail checks failed${NC}"
    exit 1
else
    echo -e "${GREEN}OK — all critical checks passed${NC}"
    exit 0
fi
