+++
kind = "note"
packages = ["cnpg-operator"]
+++
`cnpg-operator` moves to CloudNativePG 1.30.2. The first deploy after you upgrade restarts the operator, then rolls each PostgreSQL cluster once to the new instance manager, so every instance restarts. On a cluster with standbys, the rollout switches the primary over, and applications reconnect. The operator also gets delete permission on Leases, and it accepts three new backup options: `sseCustomerKey`, `s3AddressingStyle`, and `zstd` WAL compression. You do not need to change anything.
