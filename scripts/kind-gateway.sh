#!/usr/bin/env bash
# kind-gateway.sh: run Envoy Gateway with a public and a private Gateway on
# kind under Cilium default-deny, and check how the Gateways behave.
#
# Deploys clusters/test-envoy-gateway.nix with `kix deploy`, which applies
# in dependency order and waits for both Gateways to be Programmed, then
# sends requests through the proxies and checks:
#   - each Gateway's proxies and Service run in the Gateway's own
#     namespace, and the controller can create workloads only there
#   - the public Gateway redirects HTTP to HTTPS, serves the certificate
#     the ClusterIssuer signed, and adds Strict-Transport-Security
#   - a forged X-Forwarded-For from a source outside the trusted range does
#     not change the client address the proxy records
#   - a route from a namespace the tenant listener does not admit is
#     refused, and a route from the admitted namespace attaches
#   - the private Gateway's Service has the fixed cluster IP, answers a
#     client on the allow-list, and refuses every other client
#
# Requests go from the kind control-plane node. The public Gateway's
# Service is a NodePort, because kind has no load balancer.
#
# Usage: scripts/kind-gateway.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=envoy-gateway
CTX="kind-$NAME"
KEEP=${1:-}
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes --extra-experimental-features pipe-operators"
# A kubeconfig of its own, so the shared one keeps its current context.
export KUBECONFIG="${TMPDIR:-/tmp}/kc-$NAME"

need() { command -v "$1" >/dev/null || { echo "missing: $1 (try: nix shell nixpkgs#kind nixpkgs#kubectl)"; exit 1; }; }
need kind; need kubectl; need nix; need docker; need openssl

if ! kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  kind create cluster --name "$NAME" --kubeconfig "$KUBECONFIG" --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
nodes:
  - role: control-plane
  - role: worker
EOF
fi

# The CLI from this checkout. It builds the cluster, applies in dependency
# order and waits for readiness, so a deploy that returns is the first check.
$NIX run .#kix -- deploy "$NAME" --context "$CTX" -y --timeout 20m

k() { kubectl --context "$CTX" "$@"; }
node() { docker exec "$NAME-control-plane" "$@"; }
# curl from the node: the status code, then the named response header.
code() { node curl -sk -m 10 -o /dev/null -w '%{http_code}' "$@"; }

fail=0
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $desc"; else echo "FAIL: $desc"; fail=1; fi; }
is() { [ "$1" = "$2" ]; }

WORKER=$(k get node "$NAME-worker" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
HTTP=$(k -n edge get svc envoy-gateway -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
HTTPS=$(k -n edge get svc envoy-gateway -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
SA=system:serviceaccount:envoy-gateway-system:envoy-gateway

echo "== where the proxies run"
check "the public Gateway's proxies run in edge" k -n edge rollout status deploy/envoy-gateway --timeout=60s
check "the private Gateway's proxies run in internal" k -n internal rollout status deploy/private --timeout=60s
check "the controller can create Deployments in edge" is "$(k auth can-i create deployments -n edge --as "$SA")" yes
check "the controller cannot create Deployments in files" is "$(k auth can-i create deployments -n files --as "$SA" || true)" no

echo "== the public Gateway"
check "HTTP redirects to HTTPS" is \
  "$(node curl -s -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: files.envoy.test' "http://$WORKER:$HTTP/x")" \
  "301 https://files.envoy.test/x"
check "HTTPS serves the application" is \
  "$(code --resolve "files.envoy.test:$HTTPS:$WORKER" "https://files.envoy.test:$HTTPS/")" 200
# The Certificate the package wrote for the listener `https`, and the name
# in the certificate cert-manager issued for it.
check "the listener's Certificate is Ready" is \
  "$(k -n edge get certificate envoy-gateway-https -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" True
check "the certificate names the listener's hostname" bash -c \
  "kubectl --context $CTX -n edge get secret envoy-gateway-https -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep -q 'DNS:\*\.envoy\.test'"
check "responses carry Strict-Transport-Security" bash -c \
  "docker exec $NAME-control-plane curl -sk -m 10 -D - -o /dev/null --resolve files.envoy.test:$HTTPS:$WORKER https://files.envoy.test:$HTTPS/ | grep -qi '^strict-transport-security: max-age=31536000; includeSubDomains'"

# The node is outside the trusted range 192.0.2.0/24, so the proxy must
# record the node's address as the client and not the forged one.
node curl -sk -m 10 -o /dev/null -H 'X-Forwarded-For: 203.0.113.99' -H 'User-Agent: forged-xff-check' \
  --resolve "files.envoy.test:$HTTPS:$WORKER" "https://files.envoy.test:$HTTPS/"
LOG=""
for _ in 1 2 3 4 5 6; do
  LOG=$(k -n edge logs deploy/envoy-gateway -c envoy --since=120s | grep forged-xff-check | tail -1 || true)
  [ -n "$LOG" ] && break
  sleep 3
done
CLIENT=$(printf '%s' "$LOG" | sed -n 's/.*"downstream_remote_address":"\([^":]*\).*/\1/p')
check "the access log records the request" test -n "$CLIENT"
check "a forged X-Forwarded-For does not become the client address" test "$CLIENT" != "203.0.113.99"

echo "== the tenant listener"
k create namespace tenant-a --dry-run=client -o yaml | k apply -f - >/dev/null
route() { # namespace
  cat <<EOF | k apply -f - >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: tenant-check, namespace: $1 }
spec:
  parentRefs: [ { name: envoy-gateway, namespace: edge, sectionName: tenant } ]
  hostnames: [ app.tenant.test ]
  rules: [ { backendRefs: [ { name: filebrowser, port: 80 } ] } ]
EOF
}
accepted() { # namespace
  k -n "$1" get httproute tenant-check \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}/{.status.parents[0].conditions[?(@.type=="Accepted")].reason}'
}
route tenant-a; route files; sleep 5
check "a route from tenant-a attaches to the tenant listener" is "$(accepted tenant-a)" "True/Accepted"
check "a route from files is refused by the tenant listener" is "$(accepted files)" "False/NotAllowedByListeners"
k -n tenant-a delete httproute tenant-check >/dev/null; k -n files delete httproute tenant-check >/dev/null

echo "== the private Gateway"
PRIVATE=10.96.200.10
check "its Service has the fixed cluster IP" is "$(k -n internal get svc private -o jsonpath='{.spec.type}/{.spec.clusterIP}')" "ClusterIP/$PRIVATE"
check "a client on the allow-list is answered" is \
  "$(code -H 'Host: files.internal.test' -H 'X-Forwarded-For: 203.0.113.5' "http://$PRIVATE/")" 200
check "a client off the allow-list is refused" is \
  "$(code -H 'Host: files.internal.test' "http://$PRIVATE/")" 403
check "another address on no allow-list is refused" is \
  "$(code -H 'Host: files.internal.test' -H 'X-Forwarded-For: 198.51.100.7' "http://$PRIVATE/")" 403

if [ "$KEEP" != "--keep" ]; then kind delete cluster --name "$NAME" --kubeconfig "$KUBECONFIG"; fi
[ "$fail" = 0 ] && echo "all checks passed" || { echo "some checks failed"; exit 1; }
