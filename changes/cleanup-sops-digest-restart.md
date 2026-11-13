+++
kind = "note"
packages = ["secret", "experimental/stackgres-database", "experimental/clickhouse-database", "experimental/cnpg-database"]
+++
The first deploy after you upgrade changes every Secret that Kix fills from a SOPS file: it gains the annotation `kix.run/sops-digest` and loses `kix.run/content-hash`. Pods that read one of these Secrets restart once.
