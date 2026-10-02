# 2026-10-02 · `kix/packages/arc` · The derived scrape ingress for ARC listener pods has not been run on a cluster.

The PodMonitor `<name>-listeners` scrapes listener pods the ARC controller creates, on the named port `metrics`. `kix/lib/plugins/netpol/scrape.nix` gives them an ingress policy on that name and an egress rule with no port list. The same shape was verified on kind for the StackGres exporter (`pgexporter`, `clusters/test-monitoring-netpol.nix`), but no kind run has deployed arc with a runner set, so the listener target's `up` has not been observed.
