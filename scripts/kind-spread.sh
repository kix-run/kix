#!/usr/bin/env bash
# kind-spread.sh — prove derived pod spread on a multi-zone kind cluster.
#
# Creates a kind cluster "spread" with three workers labelled as zones a, b
# and c, deploys clusters/test-spread.nix, and checks that:
#   - the "zoned" pods (three, from the derived "zone" level) land one per
#     zone and get a PDB
#   - the "pinned" pods land one per node (hard on every key)
#   - the "unspread" instance (availability = "none") runs one pod with no
#     constraints and no PDB
# Then scales "pinned" to four: with maxSkew = 1 a DoNotSchedule constraint
# is even distribution, so the fourth pod lands (2/1/1), nothing pends.
#
# Usage: scripts/kind-spread.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=spread
CTX="kind-$NAME"
KEEP=${1:-}

need() { command -v "$1" >/dev/null || { echo "missing: $1 (try: nix shell nixpkgs#kind nixpkgs#kubectl)"; exit 1; }; }
need kind; need kubectl; need nix

if ! kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  kind create cluster --name "$NAME" --config scripts/kind-spread-config.yaml
fi
kubectl --context "$CTX" get nodes -L topology.kubernetes.io/zone

# Derived constraints honour taints, so a worker still carrying its
# bring-up not-ready taint is not a domain: apply only once every node is
# Ready, as a real deploy would.
kubectl --context "$CTX" wait --for=condition=Ready nodes --all --timeout=180s
nix build ./clusters#cluster-spread --extra-experimental-features pipe-operators -o result-spread
# CRDs first (the PackageInstance kind), then everything.
for f in $(find result-spread/ -name '*customresourcedefinition*.yaml'); do
  kubectl --context "$CTX" apply -f "$f"
done
kubectl --context "$CTX" wait --for=condition=Established crd --all --timeout=60s
kubectl --context "$CTX" apply -f result-spread/ -R
for d in zoned unspread pinned; do
  kubectl --context "$CTX" -n echo rollout status deploy/$d --timeout=120s
done

zone_of() { kubectl --context "$CTX" get node "$1" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'; }
placement() {
  kubectl --context "$CTX" -n echo get pods -l app.kubernetes.io/instance="$1" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}'
}

fail=0
check() { local desc=$1; shift; if "$@" >/dev/null; then echo "ok:   $desc"; else echo "FAIL: $desc"; fail=1; fi; }

zones_zoned=$(placement zoned | while read -r n; do zone_of "$n"; echo; done | sort -u | wc -l)
check "zoned: 3 pods in 3 distinct zones (got $zones_zoned)" test "$zones_zoned" -eq 3
nodes_pinned=$(placement pinned | sort -u | wc -l)
check "pinned: 3 pods on 3 distinct nodes (got $nodes_pinned)" test "$nodes_pinned" -eq 3
check "zoned has a PDB" kubectl --context "$CTX" -n echo get pdb zoned -o name
check "pinned has a PDB" kubectl --context "$CTX" -n echo get pdb pinned -o name
check "exactly two PDBs (unspread has none)" test "$(kubectl --context "$CTX" -n echo get pdb -o name | wc -l)" -eq 2
check "unspread: no constraints" test -z "$(kubectl --context "$CTX" -n echo get deploy unspread -o jsonpath='{.spec.template.spec.topologySpreadConstraints}')"

# A rolling update keeps the spread (matchLabelKeys on pod-template-hash):
# after a restart the zoned pods are still one per zone.
kubectl --context "$CTX" -n echo rollout restart deploy/zoned
kubectl --context "$CTX" -n echo rollout status deploy/zoned --timeout=120s
sleep 10
zones_after=$(placement zoned | while read -r n; do zone_of "$n"; echo; done | sort -u | wc -l)
check "zoned after a rolling restart: still 3 distinct zones (got $zones_after)" test "$zones_after" -eq 3

# Even distribution, not one-per-domain: a fourth "pinned" pod lands 2/1/1.
kubectl --context "$CTX" -n echo scale deploy/pinned --replicas=4
kubectl --context "$CTX" -n echo rollout status deploy/pinned --timeout=60s
pending=$(kubectl --context "$CTX" -n echo get pods -l app.kubernetes.io/instance=pinned --field-selector=status.phase=Pending -o name | wc -l)
check "pinned at 4 replicas on 3 nodes: nothing Pending (got $pending)" test "$pending" -eq 0
kubectl --context "$CTX" -n echo scale deploy/pinned --replicas=3

if [ "$KEEP" != "--keep" ]; then kind delete cluster --name "$NAME"; fi
exit $fail
