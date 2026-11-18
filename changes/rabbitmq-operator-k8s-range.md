+++
kind = "error"
id = "K5618"
packages = ["experimental/rabbitmq-operator"]
+++
`rabbitmq-operator` now refuses a cluster whose `k8sVersion` is below 1.31, the lowest Kubernetes version RabbitMQ Cluster Operator 2.23.3 supports. It accepted 1.25 to 1.30 before. If your cluster runs one of those versions, upgrade Kubernetes first, or stay on a Kix release with an older `rabbitmq-operator` package. A cluster that sets no `k8sVersion` is not checked.
