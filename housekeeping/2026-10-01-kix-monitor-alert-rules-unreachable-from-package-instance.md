# 2026-10-01 · `kix/lib/vocab/compose.nix` (`kix.monitor`) · The PrometheusRule part `kix.monitor` builds is unreachable from the PackageInstance unless the package lists it in `root.requires`.

The alert rules reference no other part of the instance, so the PackageInstance closure misses them and the PI wiring check fails with "'PrometheusRule/<name>-alerts' in '<instance>' is not referenced by its PackageInstance or its dependencies". It shows only when a real `prometheus` provider is wired and the PI wiring check runs; for coredns only its `kix/package-eval.nix` fixture does both. Each caller works around it by hand: coredns and harbor list their monitor and rule parts in `root.requires`, and the external-dns rework does the same. `kix.monitor` could attach the rules to the scraped Service, or the lib could add every part it builds to the PackageInstance.

The ServiceMonitor part has the same gap when the package's root is an
attrset with its own `requires`, as snapshot-controller's is (it now lists
the monitor). descheduler (`root = self.deployment`) also fails the check
with a real provider: "'ServiceMonitor/descheduler' in 'descheduler' is not
referenced by its PackageInstance or its dependencies". Its package-eval
fixture wires no `prometheus`, so every-package-evaluates does not show it.

- Hit again 2026-10-01 while reworking `kix/packages/cert-manager`: `ludo-kind-tls` built with `PrometheusRule/cert-manager-alerts` outside the PackageInstance's closure until the package listed `controllerAlerts` in `root.requires`.
- Hit again 2026-10-02 by `kix/packages/mayastor`: its ServiceMonitor and PrometheusRule warned as unreferenced until root.requires listed them.
- Hit again 2026-10-02 while reworking the monitoring packages: node-exporter and grafana list the `kix.monitor` parts in `root.requires` for the same reason.
