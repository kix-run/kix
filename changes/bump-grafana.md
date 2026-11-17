+++
kind = "note"
packages = ["grafana"]
+++
`grafana` runs Grafana 13.3.1 (was 13.1.8), which fixes security issues. The first deploy restarts the Grafana pod, and Grafana updates its database when it starts. Grafana 13.3 keeps its Prometheus, Loki, Tempo, and other data source plugins and its canvas panel in a separate folder of the image, so the package no longer mounts an empty folder there. The Elasticsearch and Zipkin data sources, which that empty folder hid, now load too. Grafana 13.3 no longer ships the deprecated Parca data source, so a Parca data source stops working. In our test, Grafana 13.1.8 could still read a database that 13.3.1 had updated, but upstream does not promise this. Copy `grafana.db` before you deploy if you may need to go back.
