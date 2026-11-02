# 2026-11-02 · `kix/lib/modules/monitoring.nix` · The monitoring module leaves `defaultRules.enabled` off, so its stack alerts on no disk, crash loop, or down target.

Package alerts leave those conditions to prometheus-default-rules
(package-review item Mo19), and node-exporter now ships only its down
alert, deferring disk, memory, and CPU to the rules' `nodeExporter` group.
A cluster that turns on `monitoring.enabled` and nothing else therefore
has no alert for a full disk, a crash-looping pod, or a missing target.
Only `ludo/base.nix` and `clusters/test-monitoring-native.nix` turn the
rules on.
