# 2026-10-02 · `kix/lib/eval/validate.nix` · StorageClass names inside operator custom resources are not checked.

Cross-resource check 20 reads `storageClassName` on PersistentVolumeClaims and StatefulSet `volumeClaimTemplates` only. A class named in an SGCluster's `pods.persistentVolume`, a VMCluster's storage spec or a CDI DataVolume builds even when nothing creates it, and the operator's claims stay Pending at runtime. Each operator package knows where its CR carries the class, so the check would need a per-kind path from the declaring package.
