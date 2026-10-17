# 2026-10-17 · `kix/packages/stackgres-database` · Two instances named alike in two namespaces collide in the server's namespace.

The package puts `<name>-bootstrap-password` and the `<name>-bootstrap-<hash>` Job in the StackGres cluster's namespace through `scope.forService`, named by the instance name alone. Two consumers that each call their database `app-db` against one StackGres cluster fail evaluation with a duplicate resource. `clickhouse-database` had the same naming and now adds the consumer's namespace (`serverSideName`); cnpg-database already prefixes its CRs with the namespace.
