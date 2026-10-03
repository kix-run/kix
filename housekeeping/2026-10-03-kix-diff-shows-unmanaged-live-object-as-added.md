# 2026-10-03 · `cli/kix-cli/src/commands/diff.rs` · `kix diff` reports an object Kix is about to take over as added although it already exists.

The live sweep reads only objects labelled `app.kubernetes.io/managed-by=kix`, so an object an installer made (`ConfigMap/coredns@kube-system` on stage1, made by RKE2's Helm chart) is absent from the old side and shows as `+` added. `kix plan` sees the live object and shows the real change to its `Corefile`. Taking over an existing object is the riskiest kind of change and the diff hides it as a creation.
