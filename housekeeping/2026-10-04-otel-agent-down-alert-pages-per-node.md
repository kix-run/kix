# The otel-collector agent's down alert pages for one node

`OtelCollectorDown` on the `agent` instance (daemonset mode) is
`up{namespace="<ns>",service="<agent>"} == 0` at severity `critical`. It
fires for each node whose collector pod stops answering, so one node going
away pages, and kube-prometheus's node and DaemonSet alerts already report
that case. BEST-PRACTICES §9.6 reserves `critical` for the service being
down or data at risk now.

Fix: for the agent, `warning` per target, or `critical` only when every
target is down (`sum by (namespace, service) (up{...}) == 0 or absent(up{...})`).
The gateway (deployment mode) keeps its down alert. Update
`clusters/test-otel-collector.rules-test.yaml`, which pins the current
behaviour. Part of step 3 of issue #192.
