+++
kind = "error"
packages = ["experimental/kubevirt"]
id = "K9806"
+++
`kubevirt` refuses a cluster whose `k8sVersion` is outside 1.35 to 1.37, the Kubernetes versions KubeVirt v1.10.0 supports. Before, it warned outside 1.34 to 1.36 and built anyway. A cluster on Kubernetes 1.34 or older upgrades Kubernetes first and updates `k8sVersion`.
