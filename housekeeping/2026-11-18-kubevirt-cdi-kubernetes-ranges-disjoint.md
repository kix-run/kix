# 2026-11-18 · `kix/packages/experimental/kubevirt`, `cdi` · The two packages accept no Kubernetes version in common.

`kubevirt` (KubeVirt v1.5.1) accepts Kubernetes 1.30 to 1.32, and `cdi` (CDI v1.66.1) accepts 1.35 to 1.36. A cluster that sets `k8sVersion` cannot build both, so a virtual machine with `dataVolumeTemplates` is out of reach on any declared version. KubeVirt supports 1.34 from v1.7, and it allows an upgrade only to the next release, so `kubevirt` needs several more bumps (v1.5.2, v1.5.3, v1.6.6, v1.7.4) before the ranges meet.
