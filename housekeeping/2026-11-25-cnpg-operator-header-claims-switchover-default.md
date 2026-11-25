# 2026-11-25 · `kix/packages/stable/cnpg-operator/default.nix` · The upgrade note says each rollout ends with a switchover, but the default restarts the primary in place.

The header's "Upgrades" paragraph says every PostgreSQL cluster's rollout
"ends with a switchover unless `primaryUpdateStrategy` is supervised". In
CloudNativePG 1.30.2, `primaryUpdateMethod` defaults to `restart` (vendored
CRD `crds/clusters.postgresql.cnpg.io.json`, and `docs/src/rolling_update.md`
upstream), so the primary pod restarts without a switchover and the database
is briefly down. A reader planning an operator upgrade expects no downtime.
