# 2026-11-18 · `kix/packages/experimental/kubevirt` · virt-synchronization-controller gets no network policy.

KubeVirt v1.9 runs virt-synchronization-controller when the alpha DecentralizedLiveMigration feature gate is in `extraSpec`. It listens on 9185 for peers in other clusters and on 8443, and the package writes no policy for it, so under default-deny it can reach nothing. The image is pinned and listed in `out.extraImages`. The policy needs a way to name peers outside the cluster.
