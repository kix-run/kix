# 2026-10-01 · `kix/packages/victoria-metrics-agent` · An agent `scrapeInterval` that differs from the cluster's only warns, although queries then double-count samples.

vmselect and vmstorage run `-dedup.minScrapeInterval` at the victoria-metrics-cluster instance's `scrapeInterval`. When the agent instance sets its own `scrapeInterval` to another value, the package's `warnings` entry reports it and the build continues, so the deployed stack returns inflated values for duplicated series. The option exists so that a trial can scrape at another interval. Removing the agent-side option, or turning the warning into an error, would make the drift impossible.

Decision required from Adam: keep the agent-side `scrapeInterval`, or derive it from the cluster only.
