# 2026-10-17 · `docs-legacy/BEST-PRACTICES.md` · Lines 268-275 give an idiom for building a ServiceMonitor directly, which package-review Mo2 flags.

Mo2 says to use `kix.monitor`, or `prometheus.out.mkPodMonitor` with `kix.alerts`. The two documents give an author opposite advice.
