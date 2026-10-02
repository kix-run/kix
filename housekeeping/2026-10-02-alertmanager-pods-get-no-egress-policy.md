# 2026-10-02 · `kix/packages/alertmanager` · Under default deny the Alertmanager pods have no egress policy, so no notification leaves the cluster.

The operator creates the Alertmanager StatefulSet, and the alertmanager package writes no `kix.operandPolicy` for its pods. Prometheus reaches them (the scrape policies open that edge), but a receiver (Slack, email, a webhook) is unreachable and every notification fails. The receivers are in the routing settings, so the package can derive the world egress ports from them or take an intent.
