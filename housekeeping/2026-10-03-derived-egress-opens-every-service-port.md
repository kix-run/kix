# 2026-10-03 · `kix/lib/plugins/netpol` · A consumer that reads one port of a Service gets egress to every port of it.

Grafana reads only Tempo's query URL (port 3200), but while one Service carried 3200, 4317, and 4318, the derived `grafana-to-tempo` ingress policy opened all three. The edge is per Service, not per port in the URL the consumer reads. The tempo package works around it with a second Service (`<name>-otlp`) for the receivers; every other multi-port Service hands its consumers the wider rule.
