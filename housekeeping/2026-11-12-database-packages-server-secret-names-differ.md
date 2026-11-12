# 2026-11-12 · `kix/packages/experimental/*-database` · The three database packages name the Secret a site must write beside the server in two different orders.

stackgres-database and clickhouse-database expect `<instance>-<namespace>-bootstrap-password`; cnpg-database expects `<namespace>-<instance>-role`. A site that moves a database between the two engines, or writes a ClusterExternalSecret for both, must remember which is which. Each package kept the name it already deployed, so changing either now renames a live Secret.
