+++
kind = "changed"
packages = ["experimental/rabbitmq-operator"]
+++
`rabbitmq-operator` now runs RabbitMQ Cluster Operator 2.23.3, up from 2.23.0. The `RabbitmqCluster` CRD gains the `/scale` subresource, so `kubectl scale rabbitmqcluster` works. Kix still sets the replica count from the cluster definition, so change the definition to scale a cluster. The first deploy restarts the operator pod and reruns its webhook check Job. In testing on kind, no RabbitMQ pod restarted.
