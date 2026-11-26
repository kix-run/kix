# 2026-11-25 · `cluster.containerd.registryConfigPath` · The option cannot say that a node reads no registry config path.

A default GKE node has no `config_path` in its containerd registry settings, and `/etc/containerd/hosts.d` does not exist. The option is a required path, so the `gke` flavor names `/etc/containerd/hosts.d`, which holds only after a node startup script sets it. `experimental/spegel` writes mirror files there, and containerd ignores them. Spegel is refused on GKE for another reason today, which hides the gap.
