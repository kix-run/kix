#!/usr/bin/env bash
# kind-operators.sh — run the operator packages on a three-zone kind cluster.
#
# Deploys clusters/test-operators.nix (coredns, velero, arc, cdi, kubevirt,
# infisical-operator, openebs) with `kix deploy`, which applies in dependency
# order and waits for every workload to be ready, then checks what the seal
# now derives for these packages:
#   - coredns (three replicas, hard on the zone key) runs one pod per zone
#   - every multi-replica Deployment and StatefulSet has its derived PDB
#   - the operators reach their operands: KubeVirt and CDI report Deployed,
#     velero answers on its metrics port, arc and infisical are Available
#
# Mayastor's data plane needs real hosts: io-engine selects nodes labelled
# openebs.io/engine=mayastor and needs hugepages, csi-node writes nvme_core
# parameters into sysfs (read-only on a kind node) and agent-ha-node mounts
# /run/udev (absent on one). The cluster turns on the upstream csi-node
# topology switch, so all three schedule nowhere on kind and only the
# control plane (etcd, NATS, agent-core, api-rest, csi-controller, the
# diskpool operator) is judged.
#
# On a NixOS host with networking.firewall.checkReversePath on, pods on
# different kind nodes cannot reach each other (the host drops bridged
# packets from the pod CIDRs it has no route to). Exempt the kind bridge:
#   sudo nft add rule inet nixos-fw rpfilter-allow \
#     iifname "br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)" accept
#
# Usage: scripts/kind-operators.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=operators
CTX="kind-$NAME"
KEEP=${1:-}
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes --extra-experimental-features pipe-operators"

need() { command -v "$1" >/dev/null || { echo "missing: $1 (try: nix shell nixpkgs#kind nixpkgs#kubectl)"; exit 1; }; }
need kind; need kubectl; need nix

if ! kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  kind create cluster --name "$NAME" --config scripts/kind-spread-config.yaml
fi
kubectl --context "$CTX" get nodes -L topology.kubernetes.io/zone
kubectl --context "$CTX" wait --for=condition=Ready nodes --all --timeout=180s

# The CLI from this checkout. It builds the cluster, applies in dependency
# order and waits for readiness, so a deploy that returns is the first check.
$NIX run .#kix -- deploy "$NAME" --flake ./clusters --context "$CTX" -y --timeout 20m

k() { kubectl --context "$CTX" "$@"; }
zone_of() { k get node "$1" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'; }
placement() {
  k -n "$1" get pods -l "$2" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}'
}

fail=0
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then echo "ok:   $desc"; else echo "FAIL: $desc"; fail=1; fi; }

# Derived spread: coredns is hard on the zone key at level zone.
zones_dns=$(placement dns app.kubernetes.io/instance=coredns | while read -r n; do zone_of "$n"; echo; done | sort -u | wc -l)
check "coredns: 3 pods in 3 distinct zones (got $zones_dns)" test "$zones_dns" -eq 3

# Derived PDBs, one per multi-replica workload.
for spec in dns/coredns kubevirt/virt-operator infisical/infisical-operator-controller-manager; do
  check "pdb ${spec#*/} in ${spec%/*}" k -n "${spec%/*}" get pdb "${spec#*/}" -o name
done

# The operators reach their operands.
check "KubeVirt CR is Deployed" test "$(k -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.phase}')" = Deployed
check "CDI CR is Deployed" test "$(k get cdi cdi -o jsonpath='{.status.phase}')" = Deployed
check "velero server is Available" k -n velero wait --for=condition=Available deploy/velero --timeout=60s
check "arc controller is Available" k -n arc-systems wait --for=condition=Available deploy -l app.kubernetes.io/name=gha-rs-controller --timeout=60s
check "infisical operator is Available" k -n infisical wait --for=condition=Available deploy/infisical-operator-controller-manager --timeout=60s

if [ "$KEEP" != "--keep" ]; then kind delete cluster --name "$NAME"; fi
exit $fail
