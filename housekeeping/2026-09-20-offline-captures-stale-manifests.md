# 2026-09-20 · Offline documentation captures · Some committed manifests are stale.

Regenerating offline captures changes manifest content unrelated to diagnostics:
VictoriaMetrics replica counts, Cilium network policies, and Service target
ports differ from the committed examples. See the `package-victoria-metrics`,
`package-cilium`, and `platform-network-policy` groups under
`docs/src/command-output/how-to/`. Those captures need a separate refresh and
review; the diagnostic wording PR keeps only captures of changed messages.
