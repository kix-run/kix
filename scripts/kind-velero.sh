#!/usr/bin/env bash
# kind-velero.sh — back up and restore a workload with Velero on kind, under
# Cilium default-deny.
#
# Deploys clusters/test-velero.nix with `kix deploy`, which waits for the
# backup location to be Available, both Schedules to be Enabled and the
# `smoke` Backup to be Completed. Then checks:
#   - the smoke backup ran a file-system backup (one PodVolumeBackup)
#   - a repository maintenance Job, launched with the data-path labels,
#     succeeds through the velero-data-path policy
#   - after the velero-smoke namespace is deleted, a restore from `smoke`
#     brings back its ConfigMap and the emptyDir file, byte for byte
#
# Needs a kind cluster without its default CNI, because the cluster's own
# cilium instance takes the CNI role.
#
# Usage: scripts/kind-velero.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=kix-velero
CTX="kind-$NAME"
KEEP=${1:-}
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes --extra-experimental-features pipe-operators"

need() { command -v "$1" >/dev/null || { echo "missing: $1 (try: nix shell nixpkgs#kind nixpkgs#kubectl)"; exit 1; }; }
need kind; need kubectl; need nix

# The cluster is deleted on every exit, failed or not, unless --keep.
cleanup() { if [ "$KEEP" != "--keep" ]; then kind delete cluster --name "$NAME"; fi; }
trap cleanup EXIT

if ! kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  config=$(mktemp -t kix-velero-kind.XXXXXX.yaml)
  cat > "$config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
EOF
  kind create cluster --name "$NAME" --config "$config"
  rm -f "$config"
fi

# The CLI from this checkout. A deploy that returns has already waited for
# the location, the Schedules and the smoke Backup.
$NIX run .#kix -- deploy velero --flake ./clusters --context "$CTX" -y --timeout 20m

k() { kubectl --context "$CTX" "$@"; }
v() { k -n velero exec deploy/velero -c velero -- /velero --namespace velero "$@"; }

fail=0
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $desc"; else echo "FAIL: $desc"; fail=1; fi; }

check "backup location is Available" test "$(k -n velero get backupstoragelocation default -o jsonpath='{.status.phase}')" = Available
for s in daily smoke-daily; do
  check "schedule $s is Enabled" test "$(k -n velero get schedule "$s" -o jsonpath='{.status.phase}')" = Enabled
done
check "backup smoke is Completed" test "$(k -n velero get backup smoke -o jsonpath='{.status.phase}')" = Completed
pvbs=$(k -n velero get podvolumebackups -l velero.io/backup-name=smoke -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}')
check "backup smoke has one Completed PodVolumeBackup (got: ${pvbs//$'\n'/ })" test "$pvbs" = Completed

# Repository maintenance runs once the frequency elapses. Shorten it so a
# Job starts within the run.
for repo in $(k -n velero get backuprepositories -o name); do
  k -n velero patch "$repo" --type merge -p '{"spec":{"maintenanceFrequency":"1m"}}'
done
maintained=""
for _ in $(seq 1 30); do
  maintained=$(k -n velero get pods -l app.kubernetes.io/component=data-path,velero.io/repo-name \
    --field-selector=status.phase=Succeeded -o name)
  [ -n "$maintained" ] && break
  sleep 10
done
check "a maintenance Job pod with the data-path labels succeeded" test -n "$maintained"

# Restore: record the workload, delete its namespace, restore it from the
# backup and compare.
before=$(k -n velero-smoke exec deploy/smoke -- sha256sum /data/file | cut -d' ' -f1)
k delete namespace velero-smoke --wait=true --timeout=5m
v restore create smoke --from-backup smoke --wait
check "restore smoke is Completed" test "$(k -n velero get restore smoke -o jsonpath='{.status.phase}')" = Completed
k -n velero-smoke rollout status deploy/smoke --timeout=5m
check "ConfigMap smoke is back" test "$(k -n velero-smoke get configmap smoke -o jsonpath='{.data.greeting}')" = "restored by velero"
after=$(k -n velero-smoke exec deploy/smoke -- sha256sum /data/file | cut -d' ' -f1)
check "the emptyDir file is restored unchanged ($before)" test "$before" = "$after"

exit $fail
