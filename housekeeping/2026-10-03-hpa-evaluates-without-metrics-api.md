# 2026-10-03 · `kix/packages/caddy`, `kix/packages/descheduler` · A cluster can ship an HPA or a metrics-driven descheduler with nothing serving metrics.k8s.io.

Caddy's HorizontalPodAutoscaler scales on CPU utilisation, and the descheduler's
`KubernetesMetrics` source reads metrics.k8s.io. kixpkgs has no metrics-server
package and no role for the metrics API, so on kind, kubeadm, and Talos the
HPA never scales and the descheduler gets no usage, with no error at
evaluation.
