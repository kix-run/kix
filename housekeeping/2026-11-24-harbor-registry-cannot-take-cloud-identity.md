# 2026-11-24 · `kix/packages/stable/harbor` · Harbor's registry cannot take a cloud identity until upstream Harbor's registry supports one on S3 and Azure.

Harbor's registry cannot take `kix.cloudIdentity`, and doc 177 and `ROADMAP.md` now say so. The package has no object storage. `registry.nix` refuses any storage driver in `registry.settings.storage` and keeps blobs on the required `storage` claim, and core hardcodes `REGISTRY_STORAGE_PROVIDER_NAME = "filesystem"`. No pod in the package calls a cloud API.

Object storage alone would not be enough. Harbor 2.15.5 builds its registry from `goharbor/distribution` tag `v2.8.3-harbor.4`. The S3 driver there builds its own credential chain from static keys, environment, the shared file and the EC2 node role. That chain has no web identity provider, so IRSA and EKS Pod Identity do not work. The Azure driver accepts only an account key. Only the GCS driver falls back to Google's default credentials, so GKE Workload Identity would work.

Decision: harbor stays off the cloud identity list until Harbor ships a registry whose S3 and Azure drivers use the ambient identity. Object storage for harbor is a separate feature, and no one has started it. Sources: goharbor/harbor#16490, distribution/distribution#3756.
