# 2026-10-03 · `kix/packages/openbao` · A namespaced SecretStore cannot use OpenBao, because its CA Secret lives in OpenBao's namespace.

External Secrets accepts `caProvider.namespace` only on a ClusterSecretStore, so `openbao.out.externalSecretsProvider` serves only ClusterSecretStores limited with `conditions`. A team that may create only namespaced stores has no supported path. A copy of `ca.crt` in each consumer namespace (reflector, trust-manager, or a ConfigMap the package writes per consumer) would close it.
