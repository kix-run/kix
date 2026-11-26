+++
kind = "fixed"
packages = ["experimental/cert-manager"]
+++
When `networkPolicy.enable = true`, `cert-manager` now allows inbound traffic from the Kubernetes API server only to its webhook pods on TCP `webhook.securePort`. Previously, all four `cert-manager` workloads (controller, webhook, cainjector, and `startupapicheck`) accepted API server traffic on every port.
