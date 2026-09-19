# 2026-09-19 · `kix/packages/python-app` · The package does not take the `availability` argument, so none of its four replica counts follow the cluster's level.

`backend`, `frontend`, `caddy` and `redis` each have a fixed replica
default; on a cluster at "node" or "zone" the shortfall check names the
web Deployment on every build (`runs 1 replica under availability
"zone"`). Seen from `clusters/test-op-misc.nix`. Either map each count
with `kix.availability.pick` (redis is a standalone store and may want
`none`) or declare `meta.availability.max`.
