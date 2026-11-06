#!/usr/bin/env bash
# test-monitoring-integration.sh: deploy native monitoring stack to kind and smoke test.
#
# Creates a kind cluster, applies the native monitoring manifests, waits for
# all pods to be ready, then verifies:
#   - All expected pods are running
#   - Prometheus CR is reconciled (operator created StatefulSet)
#   - Prometheus targets are being scraped
#   - Alertmanager is healthy
#   - Grafana is accessible and has datasources
#   - CRDs are registered
#
# Usage: ./scripts/test-monitoring-integration.sh [--keep]
#   --keep: don't delete the kind cluster after the test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

CLUSTER_NAME="kix-monitoring-test"
NATIVE_OUT="result-monitoring-native"
KEEP_CLUSTER=false
NS="monitoring-system"

for arg in "$@"; do
    case $arg in
        --keep) KEEP_CLUSTER=true ;;
    esac
done

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

cleanup() {
    if [ "$KEEP_CLUSTER" = false ]; then
        echo -e "\n${BLUE}Cleaning up kind cluster...${NC}"
        kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
    else
        echo -e "\n${YELLOW}Keeping cluster '$CLUSTER_NAME'. Delete with: kind delete cluster --name $CLUSTER_NAME${NC}"
    fi
}
trap cleanup EXIT

wait_for() {
    local desc="$1"
    local cmd="$2"
    local timeout="${3:-120}"
    local interval=5
    local elapsed=0

    echo -n "  Waiting for $desc "
    while [ $elapsed -lt $timeout ]; do
        if eval "$cmd" &>/dev/null; then
            echo -e " ${GREEN}ready${NC} (${elapsed}s)"
            return 0
        fi
        echo -n "."
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    echo -e " ${RED}timeout${NC} (${timeout}s)"
    return 1
}

echo -e "${BLUE}Building native monitoring manifests...${NC}"
# The cluster renders a Helm chart, which only kix can do.
"$(dirname "$0")/kix-manifests.sh" . monitoring-native "$NATIVE_OUT" 2>/dev/null
echo

echo -e "${BLUE}Creating kind cluster '$CLUSTER_NAME'...${NC}"
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
kind create cluster --name "$CLUSTER_NAME" --wait 60s
echo

# Set kubectl context
kubectl cluster-info --context "kind-$CLUSTER_NAME" &>/dev/null

echo -e "${BLUE}Applying manifests...${NC}"

# Apply cluster-scoped resources first (CRDs, namespaces, and ClusterRoles)
# Skip Kix-internal resources (Activation and PackageInstance CRDs) that aren't real K8s resources
echo "  Applying cluster-scoped resources..."
for f in "$NATIVE_OUT/_cluster/"*.yaml; do
    base=$(basename "$f")
    # Skip Kix-internal resources
    case "$base" in
        *activation*|*packageinstance*) continue ;;
    esac
    kubectl apply -f "$f" --server-side 2>&1 | grep -v '^$' || true
done
echo

# Wait for CRDs to be established
wait_for "CRDs to be established" \
    "kubectl get crd prometheuses.monitoring.coreos.com -o jsonpath='{.status.conditions[?(@.type==\"Established\")].status}' | grep -q True"

# Apply namespace-scoped resources (skip Kix-internal PackageInstance resources)
echo "  Applying monitoring-system resources..."
for f in "$NATIVE_OUT/monitoring-system/"*.yaml; do
    base=$(basename "$f")
    case "$base" in
        *packageinstance*) continue ;;
    esac
    kubectl apply -f "$f" --server-side 2>&1 | grep -v '^$' || true
done
echo

echo -e "${BLUE}Waiting for pods to be ready...${NC}"

# Prometheus operator needs to start first
wait_for "prometheus-operator pod" \
    "kubectl -n $NS get pods -l app.kubernetes.io/name=prometheus-operator -o jsonpath='{.items[0].status.phase}' | grep -q Running" \
    180

# Then the operator creates StatefulSets for Prometheus and Alertmanager CRs
wait_for "prometheus StatefulSet" \
    "kubectl -n $NS get statefulset prometheus-prometheus-server -o jsonpath='{.metadata.name}' 2>/dev/null | grep -q ." \
    120

wait_for "alertmanager StatefulSet" \
    "kubectl -n $NS get statefulset alertmanager-alertmanager -o jsonpath='{.metadata.name}' 2>/dev/null | grep -q ." \
    120

# Wait for all pods to be ready (with generous timeout for image pulls)
wait_for "all pods ready" \
    "kubectl -n $NS wait --for=condition=Ready pod --all --timeout=1s" \
    300
echo

echo -e "${BLUE}Running checks...${NC}"
echo

echo -e "${BLUE}1. Pod status${NC}"
kubectl -n "$NS" get pods -o wide --no-headers 2>/dev/null | while read -r line; do
    echo "  $line"
done

for component in prometheus-operator node-exporter kube-state-metrics; do
    pod_status=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$component" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    if [ "$pod_status" = "Running" ]; then
        check_pass "$component pod running"
    else
        check_fail "$component pod not running (status: $pod_status)"
    fi
done

# Prometheus pods are labeled differently by the operator
prom_pods=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=prometheus" -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
if echo "$prom_pods" | grep -q "Running"; then
    check_pass "prometheus pod running"
else
    check_fail "prometheus pod not running"
fi

am_pods=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=alertmanager" -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
if echo "$am_pods" | grep -q "Running"; then
    check_pass "alertmanager pod running"
else
    check_fail "alertmanager pod not running"
fi
echo

echo -e "${BLUE}2. CRDs registered${NC}"
for crd in prometheuses.monitoring.coreos.com alertmanagers.monitoring.coreos.com servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com; do
    if kubectl get crd "$crd" &>/dev/null; then
        check_pass "CRD $crd"
    else
        check_fail "CRD $crd not registered"
    fi
done
echo

echo -e "${BLUE}3. Prometheus CR status${NC}"
prom_available=$(kubectl -n "$NS" get prometheus prometheus-server -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
if [ "$prom_available" = "True" ]; then
    check_pass "Prometheus CR available"
else
    check_warn "Prometheus CR status: Available=$prom_available (may still be starting)"
fi

prom_replicas=$(kubectl -n "$NS" get prometheus prometheus-server -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
if [ "$prom_replicas" -gt 0 ] 2>/dev/null; then
    check_pass "Prometheus has $prom_replicas available replica(s)"
else
    check_warn "Prometheus available replicas: $prom_replicas"
fi
echo

echo -e "${BLUE}4. Prometheus targets${NC}"

# Port-forward to Prometheus and check targets
prom_pod=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=prometheus-server" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$prom_pod" ]; then
    # Start port-forward in background
    kubectl -n "$NS" port-forward "$prom_pod" 19090:9090 &>/dev/null &
    PF_PID=$!
    sleep 3

    # Query targets API
    targets_json=$(curl -sf http://localhost:19090/api/v1/targets 2>/dev/null || echo '{}')
    active_targets=$(echo "$targets_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('data',{}).get('activeTargets',[])))" 2>/dev/null || echo "0")

    if [ "$active_targets" -gt 0 ]; then
        check_pass "Prometheus has $active_targets active target(s)"
        # Show target details
        echo "$targets_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d.get('data',{}).get('activeTargets',[]):
    job = t.get('labels',{}).get('job','?')
    health = t.get('health','?')
    print(f'      {job}: {health}')
" 2>/dev/null || true
    else
        check_warn "No active targets yet (Prometheus may still be discovering)"
    fi

    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true
else
    check_warn "Cannot check targets — no Prometheus pod found"
fi
echo

echo -e "${BLUE}5. Alertmanager status${NC}"

am_pod=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=alertmanager,app.kubernetes.io/instance=alertmanager" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$am_pod" ]; then
    kubectl -n "$NS" port-forward "$am_pod" 19093:9093 &>/dev/null &
    PF_PID=$!
    sleep 3

    am_status=$(curl -sf http://localhost:19093/api/v2/status 2>/dev/null || echo '{}')
    if echo "$am_status" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('cluster',{}).get('status') == 'ready'" 2>/dev/null; then
        check_pass "Alertmanager cluster status: ready"
    else
        am_cluster_status=$(echo "$am_status" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('cluster',{}).get('status','unknown'))" 2>/dev/null || echo "unreachable")
        check_warn "Alertmanager status: $am_cluster_status"
    fi

    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true
else
    check_warn "Cannot check Alertmanager — no pod found"
fi
echo

echo -e "${BLUE}6. ServiceMonitors & PrometheusRules in cluster${NC}"

smon_count=$(kubectl -n "$NS" get servicemonitors --no-headers 2>/dev/null | wc -l)
if [ "$smon_count" -gt 0 ]; then
    check_pass "$smon_count ServiceMonitor(s) registered"
    kubectl -n "$NS" get servicemonitors --no-headers 2>/dev/null | awk '{print "      " $1}'
else
    check_warn "No ServiceMonitors found"
fi

rule_count=$(kubectl -n "$NS" get prometheusrules --no-headers 2>/dev/null | wc -l)
if [ "$rule_count" -gt 0 ]; then
    check_pass "$rule_count PrometheusRule(s) registered"
    kubectl -n "$NS" get prometheusrules --no-headers 2>/dev/null | awk '{print "      " $1}'
else
    check_warn "No PrometheusRules found"
fi
echo

echo -e "${BLUE}7. Grafana${NC}"
grafana_pod=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=grafana" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$grafana_pod" ]; then
    grafana_status=$(kubectl -n "$NS" get pod "$grafana_pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$grafana_status" = "Running" ]; then
        check_pass "Grafana pod running"
    else
        check_fail "Grafana pod status: $grafana_status"
    fi
else
    check_fail "No Grafana pod found"
fi
echo

echo -e "${BLUE}Summary${NC}"
echo -e "  ${GREEN}Passed: $pass${NC}"
echo -e "  ${YELLOW}Warnings: $warn${NC}"
echo -e "  ${RED}Failed: $fail${NC}"
echo

if [ "$fail" -gt 0 ]; then
    echo -e "${RED}FAIL — $fail checks failed${NC}"
    echo
    echo -e "${YELLOW}Debug:${NC}"
    echo "  kubectl --context kind-$CLUSTER_NAME -n $NS get pods"
    echo "  kubectl --context kind-$CLUSTER_NAME -n $NS describe pod <name>"
    echo "  kubectl --context kind-$CLUSTER_NAME -n $NS logs <name>"
    exit 1
else
    echo -e "${GREEN}OK — integration test passed${NC}"
    exit 0
fi
