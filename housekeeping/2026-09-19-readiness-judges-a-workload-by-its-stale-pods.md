# 2026-09-19 · `cli` readiness · A Deployment, StatefulSet or DaemonSet whose old pods are in CrashLoopBackOff or ImagePullBackOff is failed at once, before the rollout that fixes them has replaced a single pod.

Seen twice on kind with `clusters/test-operators.nix`: the infisical
Deployment gained its CRDs but its pod template did not change, so the
crash-looping pod stayed and `kix deploy` reported "CrashLoopBackOff
after 5 restarts" although the other replica was already healthy; the
etcd StatefulSet got a new image and the CLI reported the old pod's
"ImagePullBackOff" while the controller was still deleting it; and the
mayastor csi-node DaemonSet gained a node selector matching no node, so
its desired count went to zero, and the CLI failed it on the crash-looping
pod the controller was about to remove. The
check reads any pod the selector matches. It should read pods of the
current revision (Deployment: the newest ReplicaSet; StatefulSet:
`updateRevision`) and give the controller time to make one.
