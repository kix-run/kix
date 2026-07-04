#!/usr/bin/env bash
# Record real SSA-managed objects (with managedFields) as test fixtures for
# tests/fieldsv1_fixtures.rs. Spins up a throwaway kind cluster with an
# isolated KUBECONFIG (your kubeconfig is untouched), applies objects the way
# kix does (SSA with field manager `kix` + bookkeeping merge patch), adds
# foreign co-owner writes (kubectl patch + kubectl scale), and captures the
# objects with `kubectl get --show-managed-fields -o json`.
#
# Prerequisites: kind, kubectl, python3.
set -euo pipefail

FIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REC=$(mktemp -d)
export KUBECONFIG="$REC/kubeconfig"

cleanup() {
    kind delete cluster --name kix-drift-fixtures 2>/dev/null || true
    rm -rf "$REC"
}
trap cleanup EXIT

kind create cluster --name kix-drift-fixtures --wait 90s

cat > "$REC/manifests.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: drift-fixtures
  labels:
    app.kubernetes.io/managed-by: kix
  annotations:
    kix.dev/identity-hash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaans
    kix.dev/package: fixtures
    kix.dev/package-namespace: drift-fixtures
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fixture-web
  namespace: drift-fixtures
  labels:
    app.kubernetes.io/managed-by: kix
    app.kubernetes.io/name: fixture-web
  annotations:
    kix.dev/identity-hash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaweb
    kix.dev/package: fixtures
    kix.dev/package-namespace: drift-fixtures
    kix.dev/depends-on: requires:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaans
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: fixture-web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fixture-web
    spec:
      containers:
        - name: web
          image: nginx:1.27.0
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
            - name: metrics
              containerPort: 9090
              protocol: TCP
          env:
            - name: LOG_LEVEL
              value: info
            - name: FEATURE_FLAG
              value: "on"
          volumeMounts:
            - name: cache
              mountPath: /var/cache/nginx
        - name: sidecar
          image: busybox:1.36
          command: ["sleep", "infinity"]
          env:
            - name: ROLE
              value: sidecar
      volumes:
        - name: cache
          emptyDir: {}
---
apiVersion: v1
kind: Secret
metadata:
  name: fixture-creds
  namespace: drift-fixtures
  labels:
    app.kubernetes.io/managed-by: kix
  annotations:
    kix.dev/identity-hash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaasec
    kix.dev/package: fixtures
    kix.dev/package-namespace: drift-fixtures
type: Opaque
data:
  username: dGVzdHVzZXI=
  password: czNjcmV0LXBAc3Mh
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fixture-api
  namespace: drift-fixtures
  labels:
    app.kubernetes.io/managed-by: kix
    app.kubernetes.io/name: fixture-api
  annotations:
    kix.dev/identity-hash: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaapi
    kix.dev/package: fixtures
    kix.dev/package-namespace: drift-fixtures
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: fixture-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fixture-api
    spec:
      containers:
        - name: api
          image: nginx:1.27.0
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          env:
            - name: MODE
              value: production
EOF

# kix's SSA (manager kix, operation Apply)
kubectl apply --server-side --field-manager=kix -f "$REC/manifests.yaml"

# kix's bookkeeping merge patch (manager kix, operation Update)
for target in "namespace/drift-fixtures" "deployment/fixture-web" "secret/fixture-creds" "deployment/fixture-api"; do
    kubectl patch -n drift-fixtures "$target" --field-manager=kix --type=merge \
        -p '{"metadata":{"annotations":{"kix.dev/activations":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaact","kix.dev/applied-hash":"placeholder-recomputed-by-tests"}}}'
done

# Foreign co-owner on fixture-api: image takeover (manager kubectl-patch)
kubectl patch -n drift-fixtures deployment/fixture-api --type=strategic \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"api","image":"nginx:1.27.5"}]}}}}'
# Rogue scaling through the /scale subresource
kubectl scale -n drift-fixtures deployment/fixture-api --replicas=3
sleep 2

kubectl get -n drift-fixtures deployment/fixture-web --show-managed-fields -o json > "$FIX/deployment.json"
kubectl get -n drift-fixtures secret/fixture-creds --show-managed-fields -o json > "$FIX/secret.json"
kubectl get -n drift-fixtures deployment/fixture-api --show-managed-fields -o json > "$FIX/deployment-coowned.json"

python3 - "$FIX" <<'PYEOF'
import json, sys
fix = sys.argv[1]
for f in ['deployment.json', 'secret.json', 'deployment-coowned.json']:
    o = json.load(open(f"{fix}/{f}"))
    mans = [(m['manager'], m['operation'], m.get('subresource')) for m in o['metadata']['managedFields']]
    print(f, mans)
PYEOF
echo "FIXTURES RECORDED"
