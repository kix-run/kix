# node-exporter's comment on `float64` misstates when Prometheus fails

The comment above `NodeHighMemoryUsage`'s description in
`kix/packages/node-exporter/default.nix` says Prometheus fails a template
that uses `| float64` "only when the alert fires". That is wrong. Prometheus
parses annotation templates when it loads the rule file and refuses the
file, and prometheus-operator refuses the whole PrometheusRule.
`promtool check rules` reports `function "float64" not defined`.

The code is right (it uses `printf`); only the comment is wrong. Fix the
comment to say both Prometheus and the VictoriaMetrics converter refuse it
at load.
