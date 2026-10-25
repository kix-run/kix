# 2026-10-04 · `kix/packages/otel-collector` · Nobody has checked that the events pipeline writes one log line per Kubernetes Event.

`clusters/test-otel-collector.nix` deployed on kind on 2026-10-04, so the collectors start, pass their probes, and run with the rendered configuration. The `file/events` exporter's output under kind's CRI pipe, and the one-line-per-notification output of `k8s_objects` with `exclude_watch_type = [ "DELETED" ]`, rest on reading upstream source. Deploy with `--keep` and compare the events collector's log with `kubectl get events`.
