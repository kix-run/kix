# 2026-11-12 · `kix/packages/experimental/external-secret` · The ExternalSecret names its store by a plain string, so Kix neither orders it after the store nor checks the store exists.

`store.name` is an option, and `mkExternalSecret` takes the store as a name. A misspelt store or one deployed in a later wave shows up only at runtime, as an ExternalSecret that never syncs. Nothing publishes a SecretStore as a dependency that this package could read through `out.name`.
