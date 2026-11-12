+++
kind = "error"
packages = ["experimental/caddy"]
id = "K6965"
+++
`caddy` no longer takes `replicaCount`. Set `replicas` instead. A build that
sets `replicaCount` fails with an error that names `replicas`.
