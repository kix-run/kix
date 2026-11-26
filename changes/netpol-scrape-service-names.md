+++
kind = "fixed"
+++
A cluster with network policy on and a Prometheus server that scrapes a Service named after another resource, such as the metrics Services of `external-secrets`, no longer fails evaluation with "the string ... is not allowed to refer to a store path". This happened with both the `cilium` enforcer and standard `NetworkPolicy`.
