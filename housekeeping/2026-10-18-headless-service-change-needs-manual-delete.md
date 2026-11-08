# 2026-10-18 · `kix deploy` · A Service that becomes headless cannot be applied, and kix does not recreate it.

`spec.clusterIP` is immutable, so turning a live ClusterIP Service into `clusterIP: None` fails with "may not change once set". Hit on ludo for `monitoring-system/alertmanager` and `prometheus-server`; they had to be deleted by hand before the deploy. The preview says "invalid" without the apiserver message.
