# 2026-11-24 · `kix/lib/vocab/options.nix` · A package cannot say that its program needs a limit, so `cluster.defaultLimits` removes it like any other default.

Some limits are part of how a program works: ClickHouse sizes its memory cap from the memory limit, and nats sets equal requests and limits for the Guaranteed QoS class. `kix.options.resources` treats them like a tuning guess. With `cluster.defaultLimits.memory = "none"`, the user must set the limit on each such instance, and the packages handle it their own way: clickhouse and clickhouse-cluster refuse, nats drops to Burstable, and mayastor derives io-engine's limit outside the helper (`kix/packages/experimental/mayastor/node.nix`).

Decision required from the maintainer: keep one kind of default limit, or let a `kix.options.resources` call mark a limit as required so the cluster setting leaves it in place.
