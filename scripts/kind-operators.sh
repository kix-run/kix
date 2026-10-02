#!/usr/bin/env bash
# kind-operators.sh: run the operator packages on a three-zone kind cluster.
#
# Deploys clusters/test-operators.nix (coredns, arc, cdi, kubevirt,
# infisical-operator, zfs-localpv, snapshot-controller, and mayastor) with
# `kix deploy`, which applies in dependency order and waits for every
# workload to be ready, then checks what the seal now derives for these
# packages:
#   - coredns (three replicas, hard on the zone key) runs one pod per zone
#     and answers on its own Service
#   - every multi-replica Deployment and StatefulSet has its derived PDB
#   - the operators reach their operands: KubeVirt and CDI report Deployed,
#     arc and infisical are Available, and infisical's default connection
#     is Ready
#   - the VolumeSnapshot API, the ZFS driver, and Mayastor's control plane
#     are up
#
# The mayastor instance runs its control plane and etcd here; csi-node and
# agent-ha-node select a node label nothing sets and io-engine selects
# openebs.io/engine=mayastor, which no kind node carries. The data path is
# scripts/kind-mayastor.sh.
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
for spec in dns/coredns kubevirt/kubevirt-operator cdi/cdi-operator infisical/infisical-operator arc-systems/arc storage/snapshot-controller storage/zfs-localpv-controller mayastor/mayastor-api-rest mayastor/mayastor-etcd; do
  check "pdb ${spec#*/} in ${spec%/*}" k -n "${spec%/*}" get pdb "${spec#*/}" -o name
done

# The managed CoreDNS holds 10.96.0.53 (clusters/test-operators.nix); kind's
# bundled CoreDNS keeps 10.96.0.10.
check "coredns answers on its own Service" k -n dns run dnstest --rm -i --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local 10.96.0.53

# The operators reach their operands.
check "KubeVirt CR is Deployed" test "$(k -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.phase}')" = Deployed
check "CDI CR is Deployed" test "$(k get cdi cdi -o jsonpath='{.status.phase}')" = Deployed
check "arc controller is Available" k -n arc-systems wait --for=condition=Available deploy/arc --timeout=60s
# The lease is named by --leader-election-id, which is the instance name.
check "arc holds its leader lease" test -n "$(k -n arc-systems get lease arc -o jsonpath='{.spec.holderIdentity}')"
check "infisical operator is Available" k -n infisical wait --for=condition=Available deploy/infisical-operator --timeout=60s
# Needs cross-node pod traffic: the operator resolves app.infisical.com
# through CoreDNS on another node (see the rpfilter note above).
check "infisical default connection is Ready" test "$(k -n infisical get infisicalconnection default -o jsonpath='{.status.conditions[?(@.type=="secrets.infisical.com/IsReady")].status}')" = True

# The VolumeSnapshot API and the ZFS driver. kind nodes have no ZFS pool,
# so the node plugin registers but provisions nothing.
check "snapshot CRDs Established" k wait --for=condition=Established crd/volumesnapshotclasses.snapshot.storage.k8s.io crd/volumesnapshotcontents.snapshot.storage.k8s.io crd/volumesnapshots.snapshot.storage.k8s.io --timeout=60s
check "snapshot-controller is Available" k -n storage wait --for=condition=Available deploy/snapshot-controller --timeout=60s
check "zfs-localpv controller is Available" k -n storage wait --for=condition=Available deploy/zfs-localpv-controller --timeout=60s
check "zfs-localpv node plugin Ready on every node" test "$(k -n storage get ds zfs-localpv-node -o jsonpath='{.status.numberReady}')" = "$(k -n storage get ds zfs-localpv-node -o jsonpath='{.status.desiredNumberScheduled}')"
check "csidriver, StorageClass and VolumeSnapshotClass zfs" k get csidriver/zfs.csi.openebs.io sc/zfs volumesnapshotclass/zfs
check "one snapshot controller image in the cluster" test "$(k get pods -A -o jsonpath='{..image}' | tr ' ' '\n' | grep 'snapshot-controller:' | sort -u | wc -l)" -eq 1

# Mayastor's control plane and etcd.
check "mayastor etcd Ready" k -n mayastor rollout status statefulset/mayastor-etcd --timeout=60s
check "mayastor etcd claims on standard" test "$(k -n mayastor get pvc -l app.kubernetes.io/component=etcd -o jsonpath='{.items[*].spec.storageClassName}' | tr ' ' '\n' | sort -u)" = standard
# These four run with readOnlyRootFilesystem, so Available also checks
# that none of them writes to its root filesystem at start.
for d in agent-core api-rest operator-diskpool csi-controller; do
  check "mayastor $d Available" k -n mayastor wait --for=condition=Available deploy/mayastor-$d --timeout=60s
done
check "DiskPool CRD serves v1beta3" test "$(k get crd diskpools.openebs.io -o jsonpath='{.spec.versions[?(@.served==true)].name}')" = v1beta3
for ds in io-engine csi-node agent-ha-node; do
  check "mayastor $ds schedules nowhere" test "$(k -n mayastor get ds mayastor-$ds -o jsonpath='{.status.desiredNumberScheduled}')" = 0
done
check "io-engine may not read Secrets" test "$(k auth can-i --as=system:serviceaccount:mayastor:mayastor-io-engine get secrets -n mayastor || true)" = no
k -n mayastor port-forward svc/mayastor-api-rest 18081:8081 >/dev/null 2>&1 & pf=$!; sleep 3
check "api-rest lists no nodes" test "$(curl -s localhost:18081/v0/nodes)" = "[]"
kill $pf

if [ "$KEEP" != "--keep" ]; then kind delete cluster --name "$NAME"; fi
exit $fail
