+++
kind = "fixed"
+++
A deploy now keeps waiting when an image pull fails because of the network or the registry, such as a TLS handshake timeout, a reset connection, a 503 answer, or a rate limit. The kubelet pulls the image again, and the deploy waits within its normal readiness budget. If the budget runs out, the timeout message shows the pull error. Before, the first such error failed the workload and cancelled everything that depends on it. A pull that cannot succeed, such as a missing image or tag, a refused login, or an invalid image name, still fails at once. Failure messages now name the pod, where they used to show `pod ?/<container>`.
