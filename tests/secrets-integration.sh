#!/usr/bin/env bash
# Integration test: SOPS secret hydration via kix deploy.
#
# Prerequisites: devenv shell (provides sops, age, kind, kubectl, jq, cargo)
#
# This script:
#   1. Generates an age keypair for testing
#   2. Creates a SOPS-encrypted secret file
#   3. Creates a kind cluster
#   4. Builds and deploys the secrets cluster (clusters/test-secrets.nix)
#   5. Verifies the Secret was hydrated correctly
#   6. Verifies the pod can read the env vars
#   7. Cleans up

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KIND_CLUSTER="kix-secrets-test"
AGE_DIR=$(mktemp -d)
SOPS_FILE="$REPO_ROOT/clusters/test-secrets/db-credentials.enc.json"
SOPS_CONFIG="$REPO_ROOT/clusters/test-secrets/.sops.yaml"

# Expected secret values
EXPECTED_USERNAME="testuser"
EXPECTED_PASSWORD='s3cret-p@ss!'
EXPECTED_HOST="db.test.svc.cluster.local"
EXPECTED_PORT="5432"

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    kind delete cluster --name "$KIND_CLUSTER" 2>/dev/null || true
    rm -rf "$AGE_DIR"
    # Don't delete SOPS file — it's tracked by git for the nix build
    echo "Done."
}
trap cleanup EXIT

echo "=== Step 1: Generate age keypair ==="
age-keygen -o "$AGE_DIR/key.txt" 2>&1 | tee "$AGE_DIR/output.txt"
AGE_PUBKEY=$(grep "^Public key:" "$AGE_DIR/output.txt" | sed 's/Public key: //')
export SOPS_AGE_KEY_FILE="$AGE_DIR/key.txt"
echo "Age public key: $AGE_PUBKEY"
echo "Key file: $SOPS_AGE_KEY_FILE"

echo ""
echo "=== Step 2: Create SOPS-encrypted secret file ==="
# Create plaintext
cat > "$AGE_DIR/plain.json" <<EOF
{"username":"$EXPECTED_USERNAME","password":"$EXPECTED_PASSWORD","host":"$EXPECTED_HOST","port":"$EXPECTED_PORT"}
EOF

# Encrypt with SOPS
sops --encrypt --age "$AGE_PUBKEY" "$AGE_DIR/plain.json" > "$SOPS_FILE"
echo "Encrypted secret file created at: $SOPS_FILE"

# Verify decryption works
DECRYPTED=$(sops --decrypt --output-type json "$SOPS_FILE")
VERIFY_USER=$(echo "$DECRYPTED" | jq -r '.username')
if [ "$VERIFY_USER" != "$EXPECTED_USERNAME" ]; then
    echo "FAIL: SOPS roundtrip failed (expected '$EXPECTED_USERNAME', got '$VERIFY_USER')"
    exit 1
fi
echo "SOPS encrypt/decrypt roundtrip verified."

# Git-add the encrypted file so nix flake can see it
cd "$REPO_ROOT"
git add "$SOPS_FILE" 2>/dev/null || true

echo ""
echo "=== Step 3: Build the secrets cluster ==="
cd "$REPO_ROOT"
cargo run --manifest-path cli/Cargo.toml --bin kix -- \
    build secrets -o yaml > /dev/null
echo "Build complete."

echo ""
echo "=== Step 4: Create kind cluster ==="
kind create cluster --name "$KIND_CLUSTER" --wait 60s
kubectl --context "kind-$KIND_CLUSTER" cluster-info

echo ""
echo "=== Step 5: Deploy with kix ==="
cd "$REPO_ROOT"
cargo run --manifest-path cli/Cargo.toml --bin kix -- \
    deploy secrets \
    --yes \
    --context "kind-$KIND_CLUSTER" \
    --timeout 120s

echo ""
echo "=== Step 6: Verify Secret was hydrated ==="
# Wait a moment for the Secret to settle
sleep 2

# The Secret should have data (base64-encoded values from stringData)
SECRET_JSON=$(kubectl --context "kind-$KIND_CLUSTER" -n test get secret credentials -o json)

if [ -z "$SECRET_JSON" ] || [ "$SECRET_JSON" = "null" ]; then
    echo "FAIL: Secret 'credentials' not found in namespace 'test'"
    exit 1
fi

ERRORS=0

# kubectl returns data in base64
USERNAME=$(echo "$SECRET_JSON" | jq -r '.data.username // empty' | base64 -d 2>/dev/null || echo "")
PASSWORD=$(echo "$SECRET_JSON" | jq -r '.data.password // empty' | base64 -d 2>/dev/null || echo "")
HOST=$(echo "$SECRET_JSON" | jq -r '.data.host // empty' | base64 -d 2>/dev/null || echo "")
PORT=$(echo "$SECRET_JSON" | jq -r '.data.port // empty' | base64 -d 2>/dev/null || echo "")

echo "Secret data:"
echo "  username: $USERNAME"
echo "  password: $PASSWORD"
echo "  host: $HOST"
echo "  port: $PORT"

if [ "$USERNAME" != "$EXPECTED_USERNAME" ]; then
    echo "FAIL: username mismatch (expected '$EXPECTED_USERNAME', got '$USERNAME')"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: username matches"
fi

if [ "$PASSWORD" != "$EXPECTED_PASSWORD" ]; then
    echo "FAIL: password mismatch (expected '$EXPECTED_PASSWORD', got '$PASSWORD')"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: password matches"
fi

if [ "$HOST" != "$EXPECTED_HOST" ]; then
    echo "FAIL: host mismatch (expected '$EXPECTED_HOST', got '$HOST')"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: host matches"
fi

if [ "$PORT" != "$EXPECTED_PORT" ]; then
    echo "FAIL: port mismatch (expected '$EXPECTED_PORT', got '$PORT')"
    ERRORS=$((ERRORS + 1))
else
    echo "PASS: port matches"
fi

echo ""
echo "=== Step 7: Verify pod can read env vars ==="
# Wait for the deployment to be ready
echo "Waiting for deployment rollout..."
kubectl --context "kind-$KIND_CLUSTER" -n test rollout status deployment/secret-echo --timeout=60s

# Port forward and check the response
kubectl --context "kind-$KIND_CLUSTER" -n test port-forward svc/secret-echo 18888:80 &
PF_PID=$!
sleep 3

RESPONSE=$(curl -sf http://localhost:18888/ 2>/dev/null || echo "CURL_FAILED")
kill $PF_PID 2>/dev/null || true
wait $PF_PID 2>/dev/null || true

echo "Pod response:"
echo "$RESPONSE"
echo ""

if echo "$RESPONSE" | grep -qF "DB_USERNAME=$EXPECTED_USERNAME"; then
    echo "PASS: DB_USERNAME correctly injected"
else
    echo "FAIL: DB_USERNAME not found in pod response"
    ERRORS=$((ERRORS + 1))
fi

if echo "$RESPONSE" | grep -qF "DB_PASSWORD=$EXPECTED_PASSWORD"; then
    echo "PASS: DB_PASSWORD correctly injected"
else
    echo "FAIL: DB_PASSWORD not found in pod response"
    ERRORS=$((ERRORS + 1))
fi

if echo "$RESPONSE" | grep -qF "DB_HOST=$EXPECTED_HOST"; then
    echo "PASS: DB_HOST correctly injected"
else
    echo "FAIL: DB_HOST not found in pod response"
    ERRORS=$((ERRORS + 1))
fi

if echo "$RESPONSE" | grep -qF "DB_PORT=$EXPECTED_PORT"; then
    echo "PASS: DB_PORT correctly injected"
else
    echo "FAIL: DB_PORT not found in pod response"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "FAILED: $ERRORS test(s) failed"
    exit 1
fi
