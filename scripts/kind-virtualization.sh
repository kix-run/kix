#!/usr/bin/env bash
# kind-virtualization.sh: run KubeVirt and CDI on a three-node kind cluster
# under Cilium default-deny, and boot a virtual machine from an imported
# disk.
#
# Deploys clusters/test-virtualization.nix with `kix deploy`, which waits
# for the KubeVirt and CDI resources to be Deployed, VirtualMachine `demo`
# to be Running, DataVolume `scratch` to be Succeeded, and VirtualMachine
# `halted` to be Stopped. Then checks:
#   - both resources report phase Deployed
#   - the aggregated APIs of virt-api and cdi-apiserver are Available
#   - virt-api's admission webhook accepts a VirtualMachine (server dry run)
#   - the three objects above are in their states
#   - a second deploy with no change succeeds
# Policy drops seen by the Cilium agents during the run are saved to
# $OUT/drops-<node>.log for review.
#
# Needs /dev/kvm on the host, passed into the kind nodes; the script stops
# if a node lacks it. On a NixOS host with networking.firewall.checkReversePath
# on, pods on different kind nodes cannot reach each other; see the header of
# scripts/kind-operators.sh for the rule that exempts the kind bridge. The
# script probes cross-node traffic before judging the run and exits 2 when
# it is blocked.
#
# Usage: scripts/kind-virtualization.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=kix-virtualization
CTX="kind-$NAME"
KEEP=${1:-}
OUT=${OUT:-$(mktemp -d -t kix-virtualization.XXXXXX)}
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes --extra-experimental-features pipe-operators"

need() { command -v "$1" >/dev/null || { echo "missing: $1 (try: nix shell nixpkgs#kind nixpkgs#kubectl)"; exit 1; }; }
need kind; need kubectl; need nix; need docker

deploy_pid=""
monitor_pids=()
# The cluster is deleted on every exit, failed or not, unless --keep.
cleanup() {
  [ -n "$deploy_pid" ] && kill "$deploy_pid" 2>/dev/null || true
  for pid in "${monitor_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  if [ "$KEEP" != "--keep" ]; then kind delete cluster --name "$NAME"; fi
}
trap cleanup EXIT

if ! kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  config=$(mktemp -t kix-virtualization-kind.XXXXXX.yaml)
  cat > "$config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
  kind create cluster --name "$NAME" --config "$config"
  rm -f "$config"
fi

for node in $(kind get nodes --name "$NAME"); do
  if ! docker exec "$node" test -c /dev/kvm; then
    echo "$node has no /dev/kvm. Set extraSpec.configuration.developerConfiguration.useEmulation = true on the kubevirt instance in clusters/test-virtualization.nix, or run on a host with KVM."
    exit 2
  fi
done

k() { kubectl --context "$CTX" "$@"; }

# The CLI from this checkout. The deploy installs Cilium first, so the nodes
# become Ready while it runs.
$NIX run .#kix -- deploy virtualization --flake ./clusters --context "$CTX" -y --timeout 30m \
  > "$OUT/deploy-1.log" 2>&1 &
deploy_pid=$!
echo "deploy log: $OUT/deploy-1.log"

until k wait --for=condition=Ready nodes --all --timeout=10s >/dev/null 2>&1; do
  kill -0 "$deploy_pid" 2>/dev/null || { echo "the deploy exited before the nodes were Ready"; tail -20 "$OUT/deploy-1.log"; exit 1; }
  sleep 5
done

# Policy drops on each node while the deploy runs.
k -n kube-system rollout status ds/cilium --timeout=10m
for pod in $(k -n kube-system get pods -l k8s-app=cilium -o name); do
  node=$(k -n kube-system get "$pod" -o jsonpath='{.spec.nodeName}')
  k -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg monitor --type drop \
    > "$OUT/drops-$node.log" 2>&1 &
  monitor_pids+=($!)
done

# Cross-node probe: an httpd on one worker, fetched from the other. Cilium
# enforces policy on every endpoint, so the namespace gets its own policy.
mapfile -t workers < <(kind get nodes --name "$NAME" | grep worker | sort)
k create namespace xnode-probe
k apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: xnode-probe, namespace: xnode-probe }
spec:
  endpointSelector: { matchLabels: { app: xnode-probe } }
  ingress: [ { fromEndpoints: [ { matchLabels: { app: xnode-probe } } ], toPorts: [ { ports: [ { port: "8080", protocol: TCP } ] } ] } ]
  egress: [ { toEndpoints: [ { matchLabels: { app: xnode-probe } } ], toPorts: [ { ports: [ { port: "8080", protocol: TCP } ] } ] } ]
EOF
probe_pod() {
  k -n xnode-probe run "$1" --image=docker.io/library/busybox:1.37.0 --labels=app=xnode-probe \
    --overrides="{\"spec\":{\"nodeName\":\"$2\"}}" --restart=Never -- sh -c "$3"
}
probe_pod server "${workers[0]}" 'echo ok > /tmp/index.html; exec httpd -f -p 8080 -h /tmp'
probe_pod client "${workers[1]}" 'exec sleep 600'
k -n xnode-probe wait --for=condition=Ready pod/server pod/client --timeout=3m
server_ip=$(k -n xnode-probe get pod server -o jsonpath='{.status.podIP}')
if ! k -n xnode-probe exec client -- wget -q -T5 -O- "http://$server_ip:8080/" >/dev/null; then
  echo "cross-node traffic blocked (host rpfilter, see the kind-operators.sh header)"
  exit 2
fi
k delete namespace xnode-probe --wait=false

echo "waiting for the deploy"
if ! wait "$deploy_pid"; then
  deploy_pid=""
  echo "FAIL: the deploy did not finish; see $OUT/deploy-1.log"
  tail -40 "$OUT/deploy-1.log"
  exit 1
fi
deploy_pid=""

fail=0
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $desc"; else echo "FAIL: $desc"; fail=1; fi; }

check "KubeVirt is Deployed" test "$(k -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.phase}')" = Deployed
check "CDI is Deployed" test "$(k get cdi cdi -o jsonpath='{.status.phase}')" = Deployed
for api in v1.subresources.kubevirt.io v1beta1.upload.cdi.kubevirt.io; do
  check "APIService $api is Available" \
    test "$(k get apiservice "$api" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" = True
done
check "VirtualMachine demo is Running" test "$(k -n vm-demo get vm demo -o jsonpath='{.status.printableStatus}')" = Running
check "VirtualMachine halted is Stopped" test "$(k -n vm-demo get vm halted -o jsonpath='{.status.printableStatus}')" = Stopped
check "DataVolume scratch is Succeeded" test "$(k -n vm-demo get dv scratch -o jsonpath='{.status.phase}')" = Succeeded
check "virt-api's webhook accepts a VirtualMachine" k -n vm-demo create --dry-run=server -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata: { name: dry-run }
spec:
  runStrategy: Halted
  template: { spec: { domain: { devices: {}, resources: { requests: { memory: 64Mi } } } } }
EOF

if $NIX run .#kix -- deploy virtualization --flake ./clusters --context "$CTX" -y --timeout 10m > "$OUT/deploy-2.log" 2>&1; then
  echo "ok:   a second deploy with no change succeeds"
else
  echo "FAIL: a second deploy with no change; see $OUT/deploy-2.log"
  fail=1
fi

for pid in "${monitor_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
monitor_pids=()
for log in "$OUT"/drops-*.log; do
  echo "$(grep -c 'Policy denied' "$log" || true) policy drops in $log"
done

exit $fail
