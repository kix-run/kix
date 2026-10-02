#!/usr/bin/env bash
# kind-mayastor.sh: Mayastor's data path on kind, under Cilium default-deny.
#
# Deploys clusters/test-mayastor.nix to a kind cluster with one control-plane
# node and three workers. Each worker mounts the host's /dev and /run/udev and
# its own directory under $KIX_MAYASTOR_HOST_DIR at /var/local/mayastor, the
# io-engine host directory, where the pool files live. io-engine runs on the
# two workers labelled openebs.io/engine=mayastor; the third holds no pool,
# so a volume mounted there reaches both replicas over NVMe/TCP.
#
# Host prerequisites (`preflight` checks them and prints the fix):
#   - the nvme_tcp module loaded:        sudo modprobe nvme_tcp
#   - at least 2048 free 2 MiB hugepages: sudo sysctl -w vm.nr_hugepages=2560
#   - /run/udev present, 30G free on /
#   - KIX_MAYASTOR_HOST_DIR set to an absolute path that is absent or empty
# These change host-wide state. `teardown` removes the cluster and
# disconnects Mayastor's NVMe subsystems; restoring vm.nr_hugepages and
# unloading the nvme modules is left to the operator.
#
# Usage: scripts/kind-mayastor.sh [preflight|create|up|check|teardown]
#   up (default)  create, deploy, then check
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=kix-mayastor
CTX="kind-$NAME"
NS=mayastor
WORKERS=(worker worker2 worker3)
NIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes --extra-experimental-features pipe-operators"
H=${KIX_MAYASTOR_HOST_DIR:-}

k() { kubectl --context "$CTX" "$@"; }

fail=0
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "ok:   $desc"; else
    echo "FAIL: $desc"
    fail=1
  fi
}

refuse() {
  echo "preflight: $1" >&2
  exit 2
}

preflight() {
  [ -d /sys/module/nvme_tcp ] || refuse "the nvme_tcp module is not loaded. Run: sudo modprobe nvme_tcp"
  local free
  free=$(awk '/^HugePages_Free/ {print $2}' /proc/meminfo)
  [ "${free:-0}" -ge 2048 ] || refuse "only ${free:-0} free 2 MiB hugepages, 2048 needed. Run: sudo sysctl -w vm.nr_hugepages=2560; if fewer pages are allocated, run echo 1 | sudo tee /proc/sys/vm/compact_memory and set it again"
  [ -d /run/udev ] || refuse "/run/udev is missing; io-engine and the CSI node plugin mount it"
  local avail
  avail=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
  [ "$avail" -ge 30 ] || refuse "${avail}G free on /, 30G needed"
  [ -n "$H" ] || refuse "set KIX_MAYASTOR_HOST_DIR to an absolute path for the pool files"
  case "$H" in /*) ;; *) refuse "KIX_MAYASTOR_HOST_DIR must be an absolute path, got $H" ;; esac
  if [ -e "$H" ] && [ -n "$(ls -A "$H")" ]; then refuse "KIX_MAYASTOR_HOST_DIR ($H) is not empty"; fi
}

create() {
  preflight
  for w in "${WORKERS[@]}"; do mkdir -p "$H/$w/io-engine"; done
  fallocate -l 2GiB "$H/worker/io-engine/disk.io"
  fallocate -l 2GiB "$H/worker2/io-engine/disk.io"
  fallocate -l 1GiB "$H/worker/io-engine/disk-enc.io"
  # Each io-engine polls its own host core.
  printf 'eal_opts:\n  core_list: "1"\n' >"$H/worker/io-engine/config.yaml"
  printf 'eal_opts:\n  core_list: "2"\n' >"$H/worker2/io-engine/config.yaml"

  {
    cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
EOF
    for w in "${WORKERS[@]}"; do
      cat <<EOF
  - role: worker
    extraMounts:
      - { hostPath: /dev, containerPath: /dev }
      - { hostPath: /run/udev, containerPath: /run/udev, propagation: HostToContainer }
      - { hostPath: $H/$w, containerPath: /var/local/mayastor }
EOF
      if [ "$w" != worker3 ]; then
        cat <<EOF
    labels:
      openebs.io/engine: mayastor
EOF
      fi
    done
  } >"$H/kind-config.yaml"

  kind create cluster --name "$NAME" --config "$H/kind-config.yaml"
  # The CSI node plugin writes nvme_core parameters under /sys.
  for w in "${WORKERS[@]}"; do docker exec "$NAME-$w" mount -o remount,rw /sys; done
}

deploy() {
  $NIX run .#kix -- deploy mayastor --flake ./clusters --context "$CTX" -y --timeout 30m --log-format line 2>&1 | tee "$H/deploy-1.log"
}

# Prints the api-rest answer for a path, through a port-forward.
rest() {
  curl -sf "http://127.0.0.1:18081/v0/$1"
}

wait_volume_state() {
  local uuid=$1 want=$2
  for _ in $(seq 1 60); do
    [ "$(rest "volumes/$uuid" | jq -r .state.status)" = "$want" ] && return 0
    sleep 10
  done
  rest "volumes/$uuid" >"$H/volume-$uuid-timeout.json" || true
  return 1
}

run_check() {
  need_h
  # 0. One policy-verdict capture per Cilium agent, started before the
  # control plane restarts so cold-start traffic is captured.
  local pids=()
  for p in $(k -n kube-system get pods -l k8s-app=cilium -o name); do
    k -n kube-system exec "$p" -c cilium-agent -- cilium-dbg monitor --type policy-verdict >"$H/verdict-${p##*/}.log" 2>&1 &
    pids+=($!)
  done
  k -n "$NS" rollout restart deploy
  k -n "$NS" rollout status deploy --timeout 10m

  k -n "$NS" port-forward svc/mayastor-api-rest 18081:8081 >/dev/null 2>&1 &
  pids+=($!)
  sleep 3

  # 1-2. The deploy and the derived policies.
  check "deploy log has no address warnings" test "$(grep -c 'without using its address' "$H/deploy-1.log" || true)" = 0
  check "namespace $NS has derived policies and a default deny" bash -c "kubectl --context $CTX -n $NS get cnp -o name | grep -q default-deny"

  # 3. Pools.
  for pool in w1 w2 w1e; do
    check "DiskPool $pool is PoolReady" test "$(k -n "$NS" get diskpool "$pool" -o jsonpath='{.status.conditions[?(@.type=="PoolReady")].status}')" = True
    echo "      $pool pool_status: $(k -n "$NS" get diskpool "$pool" -o jsonpath='{.status.pool_status}')"
  done

  # 4. etcd.
  local etcd_nodes
  etcd_nodes=$(k -n "$NS" get pods -l app.kubernetes.io/component=etcd -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)
  check "three etcd members on three nodes" test "$etcd_nodes" = 3
  check "etcd cluster healthy" k -n "$NS" exec mayastor-etcd-0 -- etcdctl endpoint health --cluster

  # 5-7. A two-replica volume read from the node without a pool, a
  # snapshot of it, and a claim restored from the snapshot.
  k create namespace ms-test
  k -n ms-test apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data }
spec:
  storageClassName: ms-2
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 512Mi } }
---
apiVersion: v1
kind: Pod
metadata: { name: writer }
spec:
  nodeName: $NAME-worker3
  containers:
    - name: w
      image: docker.io/library/busybox:1.37.0
      command: [sh, -c, "head -c 67108864 /dev/urandom > /data/f && md5sum /data/f > /data/f.md5 && sleep 3600"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes: [{ name: d, persistentVolumeClaim: { claimName: data } }]
EOF
  k -n ms-test wait --for=condition=Ready pod/writer --timeout 5m
  sleep 5
  local sum uuid
  sum=$(k -n ms-test exec writer -- cat /data/f.md5 | cut -d' ' -f1)
  uuid=$(k -n ms-test get pvc data -o jsonpath='{.spec.volumeName}' | sed 's/^pvc-//')
  rest "volumes/$uuid" >"$H/volume-$uuid.json"
  check "volume Online with two Online replicas" test "$(jq -r '[.state.status, ([.state.replica_topology[] | select(.state=="Online")] | length)] | join(" ")' "$H/volume-$uuid.json")" = "Online 2"
  local nexus_node
  nexus_node=$(jq -r .state.target.node "$H/volume-$uuid.json")
  echo "      nexus on $nexus_node"

  k -n ms-test apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: { name: snap }
spec:
  volumeSnapshotClassName: ms-snap
  source: { persistentVolumeClaimName: data }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: restore }
spec:
  storageClassName: ms-2
  dataSource: { name: snap, kind: VolumeSnapshot, apiGroup: snapshot.storage.k8s.io }
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 512Mi } }
---
apiVersion: v1
kind: Pod
metadata: { name: reader }
spec:
  nodeName: $NAME-worker3
  containers:
    - name: r
      image: docker.io/library/busybox:1.37.0
      command: [sh, -c, "sleep 3600"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes: [{ name: d, persistentVolumeClaim: { claimName: restore } }]
EOF
  check "snapshot ready" k -n ms-test wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/snap --timeout 5m
  check "restored claim readable" k -n ms-test wait --for=condition=Ready pod/reader --timeout 5m
  check "restored data matches" test "$(k -n ms-test exec reader -- md5sum /data/f | cut -d' ' -f1)" = "$sum"

  # 8. Restart the io-engine that does not hold the nexus; the volume
  # degrades and rebuilds.
  local other
  other=$(k -n "$NS" get pods -l app.kubernetes.io/component=io-engine -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | awk -v n="$nexus_node" '$2 != n {print $1; exit}')
  k -n "$NS" delete pod "$other"
  check "volume rebuilds to Online within 10 minutes" wait_volume_state "$uuid" Online
  check "data still matches after the rebuild" test "$(k -n ms-test exec writer -- md5sum /data/f | cut -d' ' -f1)" = "$sum"

  # 9. An encrypted volume, and the io-engine Secret access.
  k -n ms-test apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: enc }
spec:
  storageClassName: ms-1-enc
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 256Mi } }
---
apiVersion: v1
kind: Pod
metadata: { name: enc }
spec:
  containers:
    - name: e
      image: docker.io/library/busybox:1.37.0
      command: [sh, -c, "head -c 1048576 /dev/urandom > /data/f && md5sum /data/f > /data/f.md5 && sync && sleep 3600"]
      volumeMounts: [{ name: d, mountPath: /data }]
  volumes: [{ name: d, persistentVolumeClaim: { claimName: enc } }]
EOF
  k -n ms-test wait --for=condition=Ready pod/enc --timeout 5m
  sleep 3
  check "encrypted volume reads back" k -n ms-test exec enc -- md5sum -c /data/f.md5
  local enc_uuid
  enc_uuid=$(k -n ms-test get pvc enc -o jsonpath='{.spec.volumeName}' | sed 's/^pvc-//')
  check "encrypted volume's replica is on pool w1e" test "$(rest "volumes/$enc_uuid" | jq -r '[.state.replica_topology[].pool] | join(",")')" = w1e
  check "io-engine may read the pool key" test "$(k auth can-i --as=system:serviceaccount:$NS:mayastor-io-engine get secret/pool-key -n "$NS")" = yes
  check "io-engine may not read other Secrets" test "$(k auth can-i --as=system:serviceaccount:$NS:mayastor-io-engine get secret/other -n "$NS" || true)" = no

  # 10. Policy verdicts: enforcement was on and nothing was denied.
  kill "${pids[@]}" 2>/dev/null || true
  check "no policy denies" test -z "$(grep -h 'action deny' "$H"/verdict-*.log || true)"
  check "policy allows were recorded" test "$(cat "$H"/verdict-*.log | grep -c 'action allow' || true)" -gt 0

  return "$fail"
}

need_h() { [ -n "$H" ] || { echo "set KIX_MAYASTOR_HOST_DIR" >&2; exit 2; }; }

teardown() {
  k delete namespace ms-test --wait --ignore-not-found || true
  # Before the operator goes: DiskPools carry a finalizer it removes.
  k -n "$NS" delete diskpool --all --wait || true
  # Disconnect only the NVMe subsystems Mayastor connected on this host.
  local nqn
  for nqn in $($NIX shell nixpkgs#nvme-cli -c sudo nvme list-subsys -o json | jq -r '..|.NQN? // empty' | grep '^nqn.2019-05.io.openebs:' || true); do
    echo "+ sudo nvme disconnect -n $nqn"
    $NIX shell nixpkgs#nvme-cli -c sudo nvme disconnect -n "$nqn"
  done
  kind delete cluster --name "$NAME"
}

case "${1:-up}" in
  preflight) preflight ;;
  create) create ;;
  check) run_check ;;
  teardown) teardown ;;
  up)
    create
    deploy
    run_check
    ;;
  *)
    echo "usage: $0 [preflight|create|up|check|teardown]" >&2
    exit 2
    ;;
esac
