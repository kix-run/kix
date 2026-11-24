#!/usr/bin/env bash
# kind-spread.sh: prove derived pod spread on a multi-zone kind cluster.
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
# Then the descheduler (two leader-elected replicas, 30s interval):
#   - cordoning zone c's node evicts nothing (the default profile ignores
#     the cordon taint)
#   - pods pushed out of zone c while it was cordoned come back after the
#     uncordon for "movable" (no volumes), through an eviction with a
#     Descheduled event, and stay put for the echo-server instances, whose
#     emptyDir protects them
#
# On a NixOS host with networking.firewall.checkReversePath on, pods on
# different kind nodes cannot reach each other (the host drops bridged
# packets from the pod CIDRs it has no route to). Exempt the kind bridge:
#   sudo nft add rule inet nixos-fw rpfilter-allow \
#     iifname "br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)" accept
#
# Usage: [KIND_CLUSTER=<name>] scripts/kind-spread.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=${KIND_CLUSTER:-spread}
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
nix build .#cluster-spread --extra-experimental-features pipe-operators -o result-spread
# CRDs first (the PackageInstance kind), then everything.
find result-spread/ -name '*customresourcedefinition*.yaml' -print0 |
  while IFS= read -r -d '' f; do
    kubectl --context "$CTX" apply -f "$f"
  done
kubectl --context "$CTX" wait --for=condition=Established crd --all --timeout=60s
kubectl --context "$CTX" apply -f result-spread/ -R
for d in zoned unspread pinned movable; do
  kubectl --context "$CTX" -n echo rollout status deploy/$d --timeout=120s
done
kubectl --context "$CTX" -n descheduler rollout status deploy/descheduler --timeout=180s

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
check "movable has a PDB" kubectl --context "$CTX" -n echo get pdb movable -o name
check "unspread has no PDB" test -z "$(kubectl --context "$CTX" -n echo get pdb unspread -o name --ignore-not-found)"
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

# Descheduler.
k=(kubectl --context "$CTX")
zones_of() { placement "$1" | while read -r n; do zone_of "$n"; echo; done | sort -u | grep -c .; }
desch_zones=$("${k[@]}" -n descheduler get pods -l app.kubernetes.io/instance=descheduler -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
  | while read -r n; do zone_of "$n"; echo; done | sort -u | grep -c .)
check "descheduler: 2 pods in 2 distinct zones (got $desch_zones)" test "$desch_zones" -eq 2
holder() { "${k[@]}" -n descheduler get lease descheduler -o jsonpath='{.spec.holderIdentity}'; }
lease_holder=""
for _ in $(seq 1 30); do lease_holder=$(holder 2>/dev/null || true); [ -n "$lease_holder" ] && break; sleep 2; done
echo "lease holder: $lease_holder"
check "descheduler: Lease descheduler/descheduler has a holder" test -n "$lease_holder"
check "movable: 3 pods in 3 distinct zones" test "$(zones_of movable)" -eq 3

node_c=$("${k[@]}" get nodes -l topology.kubernetes.io/zone=c -o jsonpath='{.items[0].metadata.name}')
pods_on_c() { "${k[@]}" -n echo get pods -l app.kubernetes.io/instance="$1" --field-selector=spec.nodeName="$node_c" -o name; }
movable_c=$(pods_on_c movable)
cordoned_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
"${k[@]}" cordon "$node_c"
sleep 75   # two descheduling intervals
check "cordon: movable pod on $node_c still there after two intervals" "${k[@]}" -n echo get "$movable_c"
# The leader logs this line at the end of every run.
runs=$("${k[@]}" -n descheduler logs -l app.kubernetes.io/instance=descheduler --since-time="$cordoned_at" --tail=-1 | grep -c 'Number of evictions' || true)
check "cordon: the descheduler ran at least twice while cordoned (got $runs)" test "$runs" -ge 2

# Push one movable and one zoned pod out of zone c; the replacements land in
# a and b, because the cordoned node leaves the zone count (nodeTaintsPolicy
# Honor).
"${k[@]}" -n echo delete "$movable_c" "$(pods_on_c zoned | head -1)" --wait=true
for d in movable zoned; do
  "${k[@]}" -n echo rollout status deploy/$d --timeout=120s
done
check "movable while cordoned: 2 zones" test "$(zones_of movable)" -eq 2
check "zoned while cordoned: 2 zones" test "$(zones_of zoned)" -eq 2
"${k[@]}" uncordon "$node_c"

# Up to 180s: the next run (30s interval), the eviction, and the
# replacement pod's scheduling and readiness, with margin for slow kind
# nodes.
restored=0
for _ in $(seq 1 36); do
  if [ "$(zones_of movable)" -eq 3 ]; then restored=1; break; fi
  sleep 5
done
check "descheduler: movable back in 3 zones" test "$restored" -eq 1
descheduled() {
  "${k[@]}" -n echo get events.events.k8s.io -o jsonpath='{range .items[?(@.action=="Descheduled")]}{.type} {.regarding.name}{"\n"}{end}'
}
check "descheduler: a Descheduled event on a movable pod" grep -q '^Normal movable-' <<<"$(descheduled)"
check "zoned: still 2 zones (emptyDir protects it)" test "$(zones_of zoned)" -eq 2
check "no Descheduled event on an echo-server pod" test -z "$(descheduled | grep -E ' (zoned|pinned|unspread)-')"
desch_logs=$("${k[@]}" -n descheduler logs -l app.kubernetes.io/instance=descheduler --prefix --tail=-1)
check "descheduler: no forbidden in the logs" test -z "$(grep -i forbidden <<<"$desch_logs")"
if [ "$restored" -ne 1 ]; then
  echo "lease holder now: $(holder)"
  echo "$desch_logs" | tail -50
fi

if [ "$KEEP" != "--keep" ]; then kind delete cluster --name "$NAME"; fi
exit $fail
