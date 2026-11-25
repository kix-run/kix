+++
kind = "fixed"
+++
A deploy that waits for a Deployment, StatefulSet, or DaemonSet now counts the ready pods of the new version and quotes why the first one that is not ready waits, such as the scheduler's message for a pod it cannot place. Before, a Deployment stuck on a new pod read as `2/2 ready, 2/2 updated, 1 old pod left`, because its ready count included the old pods, and `kix status` now says so too. When a StatefulSet's wait runs out of time because a pod left on an older version is not ready, the message names the pod and the `kubectl delete pod` command. With the default `OrderedReady` pod management, Kubernetes does not replace that pod by itself, even after the StatefulSet goes back to a version that works.
