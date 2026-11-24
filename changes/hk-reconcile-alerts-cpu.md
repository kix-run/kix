+++
kind = "fixed"
packages = ["experimental/rabbitmq-operator"]
+++
`rabbitmq-operator` raises its default CPU limit from `200m` to `1` core while keeping its `200m` CPU request, so Kubernetes no longer throttles the operator when it reconciles many resources at once. The first deploy after upgrading restarts the operator pods once. Instances that set `resources` keep their configured values.
