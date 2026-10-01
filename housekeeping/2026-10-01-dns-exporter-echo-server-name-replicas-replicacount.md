# 2026-10-01 · `kix/packages/{dns-exporter,echo-server}` · Both packages name their replica option `replicaCount`, where the package convention is `replicas`.

Cluster authors have to remember which spelling each package uses. The convention (`replicas`, `ints.positive`, a `kix.availability.pick` default) is in BEST-PRACTICES §6.1 and the rework's CONVENTIONS §2.6. The victoria-metrics-* packages also use `replicaCount`, but there the option feeds the VMAgent, VMAlert and VMCluster CR field of the same name.
