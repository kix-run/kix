+++
kind = "security"
packages = ["experimental/cnpg-pooler"]
cve = ["CVE-2026-19888", "CVE-2026-6668", "CVE-2026-6669", "CVE-2026-107348", "CVE-2026-107349", "CVE-2026-107350"]
workaround = "Set the cnpg-pooler options image.tag to 1.26.1 and image.digest to sha256:6c91fd7383b8b098bc0c3b71dba4e98bd568c0d301b9fc66027fbc23259c6a7d."
+++
`cnpg-pooler` now runs PgBouncer 1.26.1 instead of 1.25.2, the default of CloudNativePG 1.30.2. PgBouncer 1.26.0 and 1.26.1 fix six security issues: CVE-2026-19888, CVE-2026-6668, CVE-2026-6669, CVE-2026-107348, CVE-2026-107349, and CVE-2026-107350. The first deploy after you upgrade rolls out new pooler pods, so clients connected through the pooler reconnect once. In transaction pooling, PgBouncer now tracks `search_path` (PostgreSQL 18 and later) and `default_transaction_read_only`, so a client that sets them no longer changes them for other clients.
