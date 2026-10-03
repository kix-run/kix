# 2026-10-03 · `kix/lib/meta.nix` · A `deps.<x>.assertions` contract check never reports a missing `out` field the build reads, because the build throws first.

Dependency assertions are evaluated after the package's build. When a consumer
reads `database.out.credentials` and the provider lacks it, the cluster fails
with Nix's `attribute 'credentials' missing` at the consumer's line, not the
contract message naming the provider and field. This holds for
`kix.contracts.postgresDatabase.assertions` and the clickhouse contract alike;
the assertion only wins for misshapen fields. `kix.checkSecretKeys` avoids it
by being the binding the build reads through.
