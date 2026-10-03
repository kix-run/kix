# 2026-10-03 · `kix/packages/clickhouse/contract.nix` · The two `out` contracts live in different places and are reached differently.

The Postgres `database` contract is `kix.contracts.postgresDatabase`
(`kix/lib/vocab/postgres-database.nix`), while the clickhouse contract is a
file inside one implementation's package directory that others import by
relative path. An author adding a third contract has two precedents, and a
provider outside kixpkgs cannot import the clickhouse one.
