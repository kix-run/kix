# 149: Pod logs in ClickHouse

**Status:** Draft (shipper and table built and proven on kind, 2026-09-21; Grafana wiring open)
**Type:** Design Doc
**Related:** `143_clickhouse_packages_plan.md` (the ClickHouse packages this consumes, phase 3 of that plan), `101_monitoring_provider_landscape.md` (the metrics-side equivalent of the question in §4)

## Context

Logging is the first consumer of the ClickHouse packages. It is also their acceptance test: a package written only against the `clickhouse-database` facade, which therefore has to run unchanged on the bare single node and on the operator-run cluster.

## Design

One package, `kix/packages/clickhouse-logs`: a Vector agent on every node (DaemonSet) tails the kubelet's pod log files, shapes each line into one flat row and inserts it over ClickHouse's HTTP interface.

**The package owns the table and the cluster definition never mentions it.** `clickhouse-logs` depends on a `clickhouse-database` instance and hands it the schema through dep config injection (`deps.clickhouseDatabase.config`), the mechanism immich uses to hand stackgres-database its extensions. A cluster declares the shipper and a database with `privileges = [ "INSERT" ]`; the package asserts at eval time that the database it resolved to can be inserted into. A dashboard reads through a second `clickhouse-database` instance on the same database with `[ "SELECT" ]`, in its own namespace, with its own Secret.

**The table.** `logs`: `timestamp DateTime64(9)`, `namespace`, `pod`, `container`, `node`, `stream`, `message`, `labels Map`. `ReplicatedMergeTree`, created `ON CLUSTER '{cluster}'`, ordered by `(namespace, pod, container, timestamp)` for "this pod's logs, newest first", partitioned by day so retention drops whole parts. `retentionDays` (default 14) is the TTL. A second, idempotent statement applies a changed retention to an existing table without rewriting old parts.

**The address is a value in the config file, the password is not in it at all.** Vector's config is a ConfigMap built from a Nix attrset (`vectorConfig` merges over the package's own, null removes). The ClickHouse URL goes in as `database.out.httpUrl`, so the ordering edge and the network policy edge travel through the ConfigMap like any other address. The password is read at run time by Vector's `directory` secrets backend from the credentials Secret, mounted with `kix.mount.secret`.

**The probe needs no credentials.** Vector counts an event as sent only after ClickHouse acknowledged the insert, so the post-deploy probe reads the agent's own counters: at least one event sent by the `clickhouse` sink, no sink errors. On kind it caught both real failures described below.

## What running it taught

- **Vector 0.58 no longer expands `${VAR}` in its config.** The flag that restores it is named `--dangerously-allow-env-var-interpolation`. The first version passed the password that way, Vector sent the literal text, ClickHouse refused every insert and the probe failed the deploy. The secrets backend is the supported route.
- **A ClickHouse server at 1Gi fails under this load.** Background merges hit `MEMORY_LIMIT_EXCEEDED` within a minute of logs arriving. The ClickHouse package's 2Gi default is now documented as a floor.
- **ClickHouse logs at `trace` to its console by default**, several lines per query, and the shipper reads that console. Of the first 16,776 rows, 15,746 were ClickHouse describing the inserts of the previous batch. The ClickHouse package now sets `logger.level = information`.
- **The agent runs as uid 0.** The kubelet writes pod logs as root with mode 0640, and Kubernetes cannot give a non-root process the capability that would read them. It gets nothing else: no capabilities, a read-only root, the log directory mounted read-only. The scorecard's `security.nonRoot` rule is an error, so a cluster that enables it accepts the agent per namespace (`scorecard.ruleOverrides.byNamespace.<ns>."security.nonRoot".severity = "warning"`). That is the operator's decision to make, so the package does not make it.

## Alternatives considered

- **OpenTelemetry Collector with its ClickHouse exporter.** It brings its own `otel_logs` schema and creates the table itself, with the inserting user's DDL rights. Here the table belongs to the package and the inserting user can only insert.
- **Schema inside the shipper package as its own Job.** Every consumer would rebuild the bootstrap Job that `clickhouse-database` already is.
- **Password by environment variable.** Closed off by Vector, see above.

## Open questions

1. **Grafana.** Reading these logs in Grafana needs the `grafana-clickhouse-datasource` plugin (downloaded at start, or baked into an image) and a datasource whose password comes from the reader's Secret. The grafana package auto-wires Prometheus, Alertmanager and Loki from DI today (`kix/packages/grafana/default.nix`, `autoDatasources`); a `clickhouseDatabase ? null` dep beside them is the natural shape, with the password supplied as an env var from `out.credentials` and referenced as `$__env{...}` in the provisioned datasource. Not built: it needs a decision on how plugins are installed in an air-gapped cluster.
2. **Multi-line and structured logs.** Rows are one line each, with the message as text. JSON messages could be parsed into a `Map` column in the `row` transform; nothing consumes that yet.
3. **Kubernetes events and node journals** are separate sources. No package collects Kubernetes events today. An exporter that prints events as JSON to stdout would land them in `logs` through the pod-log path with no new code; a table of their own needs either a route on the exporter's pod labels into a second table, or a source that reads the Kubernetes API, which Vector does not have. Node journals would come from Vector's `journald` source into a table of their own.
