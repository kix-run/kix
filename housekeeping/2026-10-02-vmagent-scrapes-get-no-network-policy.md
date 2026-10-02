# 2026-10-02 · `kix/lib/plugins/netpol/scrape.nix` · VMAgent gets no scrape policy, so VictoriaMetrics scrapes are dropped under default deny.

The scrape join reads Prometheus CRs only. A VictoriaMetrics stack (victoria-metrics-agent with VMServiceScrape, VMPodScrape, or the ServiceMonitors the operator converts) has the same shape, an agent that selects scrape objects by label, and gets neither the agent's egress to its targets nor the targets' ingress from the agent. `VMAgent.factBehavior` already names the agent pods, so the join needs the VM scrape kinds and VMAgent's selector fields.
