+++
kind = "note"
packages = ["experimental/cnpg-barman-cloud"]
+++
`cnpg-barman-cloud` moves to plugin-barman-cloud 0.16.0. The first deploy after you upgrade restarts the plugin. The operator then restarts the instances of each PostgreSQL cluster that backs up through the plugin, one at a time, so that their sidecar runs the 0.16.0 image. On a cluster with standbys, the primary switches over, and applications reconnect. At availability level `pod` or higher, the plugin now runs two pods, because each pod now serves the operator. An ObjectStore accepts three new options: `s3AddressingStyle`, `s3Credentials.sseCustomerKey`, and `zstd` base backup compression. To go back, deploy the previous Kix version, but first remove these options from every ObjectStore, because plugin-barman-cloud 0.15 rejects them. You do not need to change anything to upgrade.
