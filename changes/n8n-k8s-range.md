+++
kind = "error"
id = "K1269"
packages = ["experimental/n8n"]
+++
`n8n` now refuses a cluster whose `k8sVersion` is older than 1.25, the oldest Kubernetes version upstream's n8n Helm chart supports. It accepted every version before. Move the cluster to Kubernetes 1.25 or later first. A cluster that sets no `k8sVersion` is not checked.
