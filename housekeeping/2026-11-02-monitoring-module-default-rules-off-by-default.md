# 2026-11-02 · `kix/modules/experimental/monitoring.nix` · The monitoring module leaves `defaultRules.enabled` off, so its stack alerts on no crash-looping pod or down target.

Package alerts leave those conditions to prometheus-default-rules
(package-review item Mo19). node-exporter keeps its two disk alerts while
the default rules are off, so a full disk still alerts, but a cluster that
turns on `monitoring.enabled` and nothing else has no `KubePodCrashLooping`
or `TargetDown`. Turning the rules on by default is not safe yet: on
kubeadm and RKE2 the scheduler, controller-manager, and etcd metrics listen
on 127.0.0.1, so their `Kube*Down` alerts would fire forever, and EKS has
no kube-proxy target.
