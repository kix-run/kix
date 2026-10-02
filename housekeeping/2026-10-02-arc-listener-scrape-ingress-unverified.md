# 2026-10-02 · `kix/packages/arc` · The derived scrape policy for ARC listener pods has not been run on a cluster.

The PodMonitor `<name>-listeners` scrapes listener pods the ARC controller creates, on `portNumber` 8080 (the controller's `--listener-metrics-addr`). `kix/lib/plugins/netpol/scrape.nix` gives them an ingress policy and a server egress rule on that port. The same shape was verified on kind for the StackGres exporter (`portNumber` 9187, `clusters/test-monitoring-netpol.nix`), but no kind run has deployed arc with a runner set, so the listener target's `up` has not been observed.
